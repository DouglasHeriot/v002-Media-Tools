//
//  v002_Screen_CapturePlugIn.m
//  v002 Media Tools
//
//  Created by vade on 7/16/12.
//  Copyright (c) 2012 v002. All rights reserved.
//

#import <OpenGL/CGLMacro.h>

#import "v002_Screen_CapturePlugIn.h"

#define	kQCPlugIn_Name				@"v002 Screen Capture 2.0"
#define	kQCPlugIn_Description		@"10.8 Only Screen Capture, based off of CGDisplayStream"

static  void MyTextureRelease(CGLContextObj cgl_ctx, GLuint name, void* context)
{
    glDeleteTextures(1, &name);
    
    IOSurfaceRef frameSurface = (IOSurfaceRef) context;
    IOSurfaceDecrementUseCount(frameSurface);
    CFRelease(frameSurface);
}

@interface v002_Screen_CapturePlugIn (Private)
- (IOSurfaceRef)copyNewFrame;
- (void)emitNewFrame:(IOSurfaceRef)frame;
@end
@implementation v002_Screen_CapturePlugIn

// ports
@dynamic inputDisplayID;
@dynamic inputShowCursor;
@dynamic inputOriginX;
@dynamic inputOriginY;
@dynamic inputWidth;
@dynamic inputHeight;

@dynamic outputImage;


+ (NSDictionary *)attributes
{
    return @{QCPlugInAttributeNameKey:kQCPlugIn_Name, QCPlugInAttributeDescriptionKey:kQCPlugIn_Description};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key
{
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    CGRect mainDisplayRect = CGDisplayBounds(mainDisplay);
    
    
    if([key isEqualToString:@"inputDisplayID"])
        return  @{QCPortAttributeNameKey : @"Display ID", QCPortAttributeDefaultValueKey:[NSNumber numberWithUnsignedInt:mainDisplay]};
    
    if([key isEqualToString:@"inputShowCursor"])
        return  @{QCPortAttributeNameKey:@"Show Cursor", QCPortAttributeDefaultValueKey:[NSNumber numberWithBool:NO]};
    
    
    if([key isEqualToString:@"inputOriginX"])
        return  @{QCPortAttributeNameKey : @"X Origin",
                QCPortAttributeMinimumValueKey : [NSNumber numberWithUnsignedInteger:0],
                QCPortAttributeDefaultValueKey : [NSNumber numberWithUnsignedInteger:0]};

    if([key isEqualToString:@"inputOriginY"])
        return  @{QCPortAttributeNameKey : @"Y Origin",
        QCPortAttributeMinimumValueKey : [NSNumber numberWithUnsignedInteger:0],
        QCPortAttributeDefaultValueKey : [NSNumber numberWithUnsignedInteger:0]};

    if([key isEqualToString:@"inputWidth"])
        return  @{QCPortAttributeNameKey : @"Width",
        QCPortAttributeMinimumValueKey : [NSNumber numberWithUnsignedInteger:0],
        QCPortAttributeDefaultValueKey : [NSNumber numberWithUnsignedInteger:mainDisplayRect.size.width]};

    if([key isEqualToString:@"inputHeight"])
        return  @{QCPortAttributeNameKey : @"Height",
        QCPortAttributeMinimumValueKey : [NSNumber numberWithUnsignedInteger:0],
        QCPortAttributeDefaultValueKey : [NSNumber numberWithUnsignedInteger:mainDisplayRect.size.height]};

      
	return nil;
}

+ (NSArray*) sortedPropertyPortKeys
{
	return @[@"inputPath",
             @"outputMovieDidEnd"];
}

+ (QCPlugInExecutionMode)executionMode
{
	return kQCPlugInExecutionModeProvider;
}

+ (QCPlugInTimeMode)timeMode
{
	return kQCPlugInTimeModeIdle;
}

- (id)init
{
	self = [super init];
	if (self)
    {
        displayQueue = dispatch_queue_create("info.v002.v002ScreenCaptureQueue", DISPATCH_QUEUE_SERIAL);
    }
	
	return self;
}

- (void)finalize
{
    dispatch_release(displayQueue);
    if (displayStream) CFRelease(displayStream);
    [super finalize];
}

- (void) dealloc
{
    dispatch_release(displayQueue);
    if (displayStream) CFRelease(displayStream);
    [super dealloc];
}

- (IOSurfaceRef)getAndSetFrame:(IOSurfaceRef)new
{
    bool success = false;
    IOSurfaceRef old;
    do {
        old = updatedSurface;
        success = OSAtomicCompareAndSwapPtrBarrier(old, new, (void * volatile *)&updatedSurface);
    } while (!success);
    return old;
}

- (IOSurfaceRef)copyNewFrame
{
    return [self getAndSetFrame:NULL];
}

- (void)emitNewFrame:(IOSurfaceRef)frame
{
    CFRetain(frame);
    [self getAndSetFrame:frame];
}

@end

@implementation v002_Screen_CapturePlugIn (Execution)

- (BOOL)startExecution:(id <QCPlugInContext>)context
{
    if(displayStream)
        CGDisplayStreamStart(displayStream);
	
    return YES;
}

- (void)enableExecution:(id <QCPlugInContext>)context
{
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments
{
    CGLContextObj cgl_ctx = [context CGLContextObj];
        
    if([self didValueForInputKeyChange:@"inputDisplayID"])
    {
        NSLog(@"new Display ID");
        
        // Cleanup existing CGDisplayStream;
        
        if(displayStream)
        {
            CFRelease(displayStream);
            displayStream = NULL;
        }
        
        // create a new CGDisplayStream
        CGDirectDisplayID display = (CGDirectDisplayID) self.inputDisplayID;
		
		// Get the backingScaleFactor, from the corresponding NSScreen object
		CGFloat backingScaleFactor = 1.0;
		for(NSScreen *screen in [NSScreen screens])
		{
			if([screen.deviceDescription[@"NSScreenNumber"] integerValue] == display)
				backingScaleFactor = screen.backingScaleFactor;
		}
		
		// Get bounds, and account for backingScaleFactor
        CGRect bounds = CGDisplayBounds(display);
		bounds.size.width *= backingScaleFactor;
		bounds.size.height *= backingScaleFactor;
		
        displayStream = CGDisplayStreamCreateWithDispatchQueue(display,
                                                               bounds.size.width,
                                                               bounds.size.height,
                                                               'BGRA',
                                                               nil,
                                                               displayQueue,
                                                               ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef)
                                                               {
                                                                   if(status == kCGDisplayStreamFrameStatusFrameComplete && frameSurface)
                                                                   {
                                                                       // As per CGDisplayStreams header
                                                                       IOSurfaceIncrementUseCount(frameSurface);
                                                                       // -emitNewFrame: retains the frame
                                                                       [self emitNewFrame:frameSurface];
                                                                   }
                                                               });
        
        CGDisplayStreamStart(displayStream);
        
    }
    
    IOSurfaceRef frameSurface = [self copyNewFrame];
    if (frameSurface)
    {
        size_t width = IOSurfaceGetWidth(frameSurface);
        size_t height = IOSurfaceGetHeight(frameSurface);
        
        GLuint newTextureForSurface;
        
        glPushAttrib(GL_TEXTURE_BIT);
        
        glGenTextures(1, &newTextureForSurface);
        glBindTexture(GL_TEXTURE_RECTANGLE_EXT,newTextureForSurface);
        
        CGLTexImageIOSurface2D(cgl_ctx, GL_TEXTURE_RECTANGLE_EXT, GL_RGBA, (GLsizei)width, (GLsizei)height, GL_BGRA, GL_UNSIGNED_BYTE, frameSurface, 0);
        
        glPopAttrib();
        
        // emit a new frame
        CGColorSpaceRef cspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
        id<QCPlugInOutputImageProvider> provider = [context outputImageProviderFromTextureWithPixelFormat:QCPlugInPixelFormatBGRA8
                                                               pixelsWide:width
                                                               pixelsHigh:height
                                                                     name:newTextureForSurface
                                                                  flipped:YES
                                                          releaseCallback:MyTextureRelease
                                                           releaseContext:frameSurface
                                                               colorSpace:cspace
                                                         shouldColorMatch:YES];
        
        CGColorSpaceRelease(cspace);

        self.outputImage = provider;
    }
    
    return YES;
}

- (void)disableExecution:(id <QCPlugInContext>)context
{
}

- (void)stopExecution:(id <QCPlugInContext>)context
{
    if(displayStream)
        CGDisplayStreamStop(displayStream);
}


@end

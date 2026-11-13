#ifndef VideoToolboxDecoder_h
#define VideoToolboxDecoder_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VideoToolboxDecoderFrameHandler)(CVPixelBufferRef pixelBuffer);

@interface VideoToolboxDecoder : NSObject

@property (nonatomic, copy, nullable) VideoToolboxDecoderFrameHandler onFrame;

- (nullable instancetype)initWithFormatDescription:(CMVideoFormatDescriptionRef)formatDescription;
- (BOOL)decode:(CMSampleBufferRef)sampleBuffer;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

#endif /* VideoToolboxDecoder_h */

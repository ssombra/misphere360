#import "VideoToolboxDecoder.h"

@interface VideoToolboxDecoder () {
    VTDecompressionSessionRef _decompressionSession;
}
@end

static void decompressionOutputCallback(
    void *decompressionOutputRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration)
{
    if (status == noErr && imageBuffer != NULL) {
        VideoToolboxDecoder *decoder = (__bridge VideoToolboxDecoder *)decompressionOutputRefCon;
        VideoToolboxDecoderFrameHandler handler = decoder.onFrame;
        if (handler) {
            handler((CVPixelBufferRef)imageBuffer);
        }
    }
}

@implementation VideoToolboxDecoder

- (nullable instancetype)initWithFormatDescription:(CMVideoFormatDescriptionRef)formatDescription {
    self = [super init];
    if (!self) return nil;

    VTDecompressionOutputCallbackRecord callbackRecord;
    callbackRecord.decompressionOutputCallback = decompressionOutputCallback;
    callbackRecord.decompressionOutputRefCon = (__bridge void *)self;

    NSDictionary *destinationImageBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionSessionRef session = NULL;
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        formatDescription,
        NULL,
        (__bridge CFDictionaryRef)destinationImageBufferAttributes,
        &callbackRecord,
        &session
    );

    if (status != noErr || session == NULL) {
        NSLog(@"[VideoToolboxDecoder] Error creando VTDecompressionSession: %d", (int)status);
        return nil;
    }

    _decompressionSession = session;
    return self;
}

- (BOOL)decode:(CMSampleBufferRef)sampleBuffer {
    if (!_decompressionSession) return NO;

    VTDecodeInfoFlags flagsOut = 0;
    VTDecodeFrameFlags decodeFlags = kVTDecodeFrame_EnableAsynchronousDecompression | kVTDecodeFrame_1xRealTimePlayback;
    OSStatus status = VTDecompressionSessionDecodeFrame(
        _decompressionSession,
        sampleBuffer,
        decodeFlags,
        NULL,
        &flagsOut
    );

    return (status == noErr);
}

- (void)invalidate {
    if (_decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
}

- (void)dealloc {
    [self invalidate];
}

@end

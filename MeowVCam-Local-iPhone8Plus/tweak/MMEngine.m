#import "MMEngine.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <pthread.h>
#import <math.h>
#import "../core/MMAudioMix.h"
#define MM_VIDEO_SLOTS 12
typedef struct { CVPixelBufferRef pixels; double time, rotation; } MMVideoSlot;
@interface MMEngine () {
    MMDecoder *_decoder;
    MMPCMCache *_audio;
    pthread_mutex_t _videoLock;
    MMVideoSlot _video[MM_VIDEO_SLOTS];
    CIContext *_imageContext;
    dispatch_queue_t _renderQueue;
    BOOL _renderBusy;
    double _renderStarted, _lastRenderRequest, _renderedTime;
    uint64_t _generation;
    CVPixelBufferRef _rendered;
    CVPixelBufferPoolRef _renderPool;
    size_t _poolWidth, _poolHeight;
    OSType _poolFormat;
}
@property(atomic, readwrite) BOOL active;
- (void)publishVideo:(const uint8_t *)p width:(int)w height:(int)h
              stride:(int)stride time:(double)t rotation:(double)rotation;
- (void)resetMedia;
- (void)renderSource:(CVPixelBufferRef)source width:(size_t)width height:(size_t)height
             format:(OSType)format time:(double)time rotation:(double)rotation generation:(uint64_t)generation;
@end
static void decodedVideo(void *context, const uint8_t *p, int w, int h,
                         int stride, double time, double rotation) {
    @autoreleasepool {
        [(__bridge MMEngine *)context publishVideo:p width:w height:h
                                          stride:stride time:time rotation:rotation];
    }
}
static void decodedAudio(void *context, const float *p, size_t n, double t);
static void decoderStatus(void *context, const char *message) {
    (void)context;
    @autoreleasepool { NSLog(@"[MeowVCam] %s", message); }
}
static void decoderReset(void *context) { [(__bridge MMEngine *)context resetMedia]; }
static double captureTime(CMSampleBufferRef sample) {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    CMTime host = CMClockGetTime(CMClockGetHostTimeClock());
    double delta = CMTimeGetSeconds(CMTimeSubtract(pts, host));
    return mm_monotonic_seconds() + (isfinite(delta) && fabs(delta) < 2 ? delta : 0);
}
static BOOL supportedPCM(AudioStreamBasicDescription f) {
    if (f.mFormatID != kAudioFormatLinearPCM || f.mChannelsPerFrame < 1 ||
        f.mChannelsPerFrame > 2 || f.mSampleRate < 8000 || f.mSampleRate > 192000 ||
        (f.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        !(f.mFormatFlags & kAudioFormatFlagIsPacked)) return NO;
    BOOL type = ((f.mFormatFlags & kAudioFormatFlagIsFloat) && f.mBitsPerChannel == 32) ||
        (!(f.mFormatFlags & kAudioFormatFlagIsFloat) &&
         (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) && f.mBitsPerChannel == 16);
    UInt32 sampleBytes = f.mBitsPerChannel / 8;
    UInt32 expected = sampleBytes * ((f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : f.mChannelsPerFrame);
    return type && f.mBytesPerFrame == expected;
}
@implementation MMEngine
+ (instancetype)shared {
    static MMEngine *instance; static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MMEngine new]; }); return instance;
}
 + (NSDictionary *)configurationForCurrentApplication {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.meowmeow.vcam.local.plist"];
    return [d[@"enabled"] boolValue] ? d : nil;
}
- (instancetype)init {
    if ((self = [super init])) {
        _audio = calloc(1, sizeof(MMPCMCache));
        if (!_audio || mm_pcm_init(_audio)) { free(_audio); return nil; }
        if (pthread_mutex_init(&_videoLock, NULL)) {
            mm_pcm_destroy(_audio); free(_audio); return nil;
        }
        _imageContext = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
        _renderQueue = dispatch_queue_create("com.meowmeow.local.render", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_renderQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    }
    return self;
}
- (BOOL)startWithConfiguration:(NSDictionary *)d {
    if (_decoder) return YES;
    NSString *source = d[@"source"];
    NSString *mode = d[@"mode"];
    if (![source isKindOfClass:NSString.class] || !source.length) return NO;
    if ([mode isEqualToString:@"local"]) {
        if (![source hasPrefix:@"/"] || ![[NSFileManager defaultManager] isReadableFileAtPath:source]) {
            NSLog(@"[MeowVCam] Local file is not readable in this process."); return NO;
        }
    } else return NO;
    NSInteger edge = [d[@"videoLongEdge"] integerValue]; if (!edge) edge = 720;
    MMDecoderCallbacks cb = {decodedVideo, decodedAudio, decoderStatus, decoderReset, (__bridge void *)self};
    _decoder = mm_decoder_create(source.UTF8String, [d[@"loop"] boolValue], (int)edge, cb);
    if (!_decoder || mm_decoder_start(_decoder)) {
        mm_decoder_destroy(_decoder); _decoder = NULL; return NO;
    }
    self.active = YES;
    return YES;
}
- (NSString *)audioMode { return @"mix"; }
- (void)reloadConfiguration {
    self.active = NO;
    mm_decoder_destroy(_decoder); _decoder = NULL;
    [self resetMedia];
    NSDictionary *configuration = [MMEngine configurationForCurrentApplication];
    if (configuration) [self startWithConfiguration:configuration];
}

- (void)publishVideo:(const uint8_t *)p width:(int)w height:(int)h
              stride:(int)stride time:(double)t rotation:(double)rotation {
    CVPixelBufferRef pixels = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                           (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess) return;
    if (CVPixelBufferLockBaseAddress(pixels, 0) != kCVReturnSuccess) { CFRelease(pixels); return; }
    uint8_t *dest = CVPixelBufferGetBaseAddress(pixels);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(pixels);
    for (int y = 0; y < h; y++) memcpy(dest + y * rowBytes, p + y * stride, (size_t)w * 4);
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    pthread_mutex_lock(&_videoLock);
    size_t slot = 0;
    for (size_t i = 0; i < MM_VIDEO_SLOTS; i++) {
        if (!_video[i].pixels) { slot = i; break; }
        if (_video[i].time < _video[slot].time) slot = i;
    }
    if (_video[slot].pixels) CFRelease(_video[slot].pixels);
    _video[slot] = (MMVideoSlot){pixels, t, rotation};
    pthread_mutex_unlock(&_videoLock);
}
- (void)writeAudio:(const float *)p frames:(size_t)n time:(double)t {
    mm_pcm_write(_audio, t, p, n);
}
- (void)resetMedia {
    mm_pcm_clear(_audio);
    pthread_mutex_lock(&_videoLock);
    _generation++;
    if (_rendered) { CFRelease(_rendered); _rendered = NULL; }
    for (size_t i = 0; i < MM_VIDEO_SLOTS; i++) {
        if (_video[i].pixels) CFRelease(_video[i].pixels);
        _video[i] = (MMVideoSlot){0};
    }
    pthread_mutex_unlock(&_videoLock);
}
- (CMSampleBufferRef)copyVideoSample:(CMSampleBufferRef)original {
    CVImageBufferRef live = CMSampleBufferGetImageBuffer(original);
    if (!live) return NULL;
    OSType format = CVPixelBufferGetPixelFormatType(live);
    if (format != kCVPixelFormatType_32BGRA &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return NULL;
    size_t w = CVPixelBufferGetWidth(live), h = CVPixelBufferGetHeight(live);
    if (!w || !h || w > 1920 || h > 1920) return NULL;
    double time = captureTime(original), selectedTime = -INFINITY, rotation = 0;
    double now = mm_monotonic_seconds();
    CVPixelBufferRef source = NULL, target = NULL;
    uint64_t generation;
    // A camera callback never waits for the decode or render worker.
    if (pthread_mutex_trylock(&_videoLock)) return NULL;
    if (_renderBusy && now - _renderStarted > 0.5) {
        pthread_mutex_unlock(&_videoLock);
        self.active = NO;
        NSLog(@"[MeowVCamLocal] Rendering timed out; replacement disabled for this session.");
        return NULL;
    }
    for (size_t i = 0; i < MM_VIDEO_SLOTS; i++) {
        if (_video[i].pixels && _video[i].time <= time + 0.003 &&
            _video[i].time > selectedTime) {
            source = _video[i].pixels; selectedTime = _video[i].time;
            rotation = _video[i].rotation;
        }
    }
    if (_rendered && CVPixelBufferGetWidth(_rendered) == w && CVPixelBufferGetHeight(_rendered) == h &&
        CVPixelBufferGetPixelFormatType(_rendered) == format && time - _renderedTime < 0.25) {
        target = _rendered; CFRetain(target);
    }
    BOOL schedule = source && time - selectedTime < 0.25 && !_renderBusy && now - _lastRenderRequest >= 1.0 / 30.0;
    generation = _generation;
    if (schedule) {
        CFRetain(source); _renderBusy = YES; _renderStarted = now; _lastRenderRequest = now;
    }
    pthread_mutex_unlock(&_videoLock);
    if (schedule) {
        dispatch_async(_renderQueue, ^{
            @autoreleasepool {
                [self renderSource:source width:w height:h format:format time:selectedTime rotation:rotation generation:generation];
                CFRelease(source);
            }
        });
    }
    // Until a matching frame is ready, retain normal camera processing.
    if (!target) return NULL;
    CMVideoFormatDescriptionRef description = NULL;
    CMSampleBufferRef result = NULL;
    CMSampleTimingInfo timing = {CMSampleBufferGetDuration(original),
        CMSampleBufferGetPresentationTimeStamp(original), CMSampleBufferGetDecodeTimeStamp(original)};
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, target, &description) == noErr)
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, target, description, &timing, &result);
    if (description) CFRelease(description); CFRelease(target);
    return result;
}
- (void)renderSource:(CVPixelBufferRef)source width:(size_t)w height:(size_t)h
             format:(OSType)format time:(double)t rotation:(double)rotation generation:(uint64_t)generation {
    CVPixelBufferRef target = NULL;
    @try {
        if (!_renderPool || _poolWidth != w || _poolHeight != h || _poolFormat != format) {
            if (_renderPool) { CFRelease(_renderPool); _renderPool = NULL; }
            NSDictionary *attributes = @{(id)kCVPixelBufferWidthKey:@(w), (id)kCVPixelBufferHeightKey:@(h),
                (id)kCVPixelBufferPixelFormatTypeKey:@(format), (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
            CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &_renderPool);
            _poolWidth = w; _poolHeight = h; _poolFormat = format;
        }
        NSDictionary *limits = @{(id)kCVPixelBufferPoolAllocationThresholdKey:@4};
        if (_renderPool && CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
            _renderPool, (__bridge CFDictionaryRef)limits, &target) == kCVReturnSuccess) {
            CIImage *image = [CIImage imageWithCVPixelBuffer:source];
            image = [image imageByApplyingTransform:CGAffineTransformMakeRotation(rotation * M_PI / 180.0)];
            CGRect extent = image.extent;
            image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
            extent = image.extent;
            CGFloat scale = MAX(w / extent.size.width, h / extent.size.height);
            image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
            extent = image.extent;
            image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
                ((CGFloat)w - extent.size.width) / 2, ((CGFloat)h - extent.size.height) / 2)];
            image = [image imageByCroppingToRect:CGRectMake(0, 0, w, h)];
            CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
            @try { [_imageContext render:image toCVPixelBuffer:target bounds:CGRectMake(0, 0, w, h) colorSpace:colors]; }
            @finally { CGColorSpaceRelease(colors); }
        }
    } @catch (NSException *exception) {
        NSLog(@"[MeowVCamLocal] Background render failed: %@", exception.reason);
        if (target) { CFRelease(target); target = NULL; }
        self.active = NO;
    }
    pthread_mutex_lock(&_videoLock);
    if (target && self.active && generation == _generation) {
        if (_rendered) CFRelease(_rendered);
        _rendered = target; _renderedTime = t; target = NULL;
    }
    _renderBusy = NO;
    pthread_mutex_unlock(&_videoLock);
    if (target) CFRelease(target);
}
- (BOOL)fillAudioBuffers:(AudioBufferList *)buffers format:(AudioStreamBasicDescription)f
                 frames:(UInt32)n atTime:(double)t {
    if (!supportedPCM(f) || n > 4096 || !buffers) return NO;
    BOOL planar = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = f.mChannelsPerFrame;
    if (buffers->mNumberBuffers != (planar ? channels : 1)) return NO;
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++)
        if (!buffers->mBuffers[b].mData || buffers->mBuffers[b].mDataByteSize < n * f.mBytesPerFrame ||
            buffers->mBuffers[b].mNumberChannels != (planar ? 1 : channels)) return NO;
    float scratch[4096 * 2];
    mm_pcm_read(_audio, t, f.mSampleRate, channels, scratch, n);
    BOOL floating = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    for (UInt32 i = 0; i < n; i++) for (UInt32 ch = 0; ch < channels; ch++) {
        void *data = buffers->mBuffers[planar ? ch : 0].mData;
        size_t index = planar ? i : i * channels + ch;
        float video = scratch[i * channels + ch];
        if (floating) ((float *)data)[index] = mm_audio_mix_float(((float *)data)[index], video);
        else ((int16_t *)data)[index] = mm_audio_mix_s16(((int16_t *)data)[index], video);
    }
    return YES;
}
- (CMSampleBufferRef)copyAudioSample:(CMSampleBufferRef)original {
    CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(original);
    if (!format || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) return NULL;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd || !supportedPCM(*asbd)) return NULL;
    CMItemCount count = CMSampleBufferGetNumSamples(original);
    if (count < 1 || count > 4096) return NULL;
    BOOL planar = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = asbd->mChannelsPerFrame;
    size_t bytes = (size_t)count * asbd->mBytesPerFrame * (planar ? channels : 1);
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, bytes,
        kCFAllocatorDefault, NULL, 0, bytes, 0, &block) != kCMBlockBufferNoErr) return NULL;
    if (CMBlockBufferAssureBlockMemory(block) != kCMBlockBufferNoErr) { CFRelease(block); return NULL; }
    char *p = NULL;
    if (CMBlockBufferGetDataPointer(block, 0, NULL, NULL, &p) != kCMBlockBufferNoErr) {
        CFRelease(block); return NULL;
    }
    struct { UInt32 count; AudioBuffer buffer[2]; } storage = {0};
    AudioBufferList *list = (AudioBufferList *)&storage;
    list->mNumberBuffers = planar ? channels : 1;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        list->mBuffers[i].mNumberChannels = planar ? 1 : channels;
        list->mBuffers[i].mDataByteSize = (UInt32)count * asbd->mBytesPerFrame;
        list->mBuffers[i].mData = p + (planar ? i * count * asbd->mBytesPerFrame : 0);
    }
    // Start with an independent copy of the real microphone PCM. Never modify
    // the original sample: other capture clients may still need that buffer.
    if (CMSampleBufferCopyPCMDataIntoAudioBufferList(original, 0, (int32_t)count, list) != noErr) {
        CFRelease(block); return NULL;
    }
    if (![self fillAudioBuffers:list format:*asbd frames:(UInt32)count atTime:captureTime(original)]) {
        CFRelease(block); return NULL;
    }
    CMSampleTimingInfo timing = {CMTimeMake(1, (int32_t)asbd->mSampleRate),
        CMSampleBufferGetPresentationTimeStamp(original), kCMTimeInvalid};
    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, count, 1, &timing, 0, NULL, &result);
    if (result) CMSetAttachment(result, CFSTR("com.meowmeow.vcam.local.audioMixed"),
        kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    CFRelease(block); return result;
}
@end
static void decodedAudio(void *context, const float *p, size_t n, double t) {
    [(__bridge MMEngine *)context writeAudio:p frames:n time:t];
}

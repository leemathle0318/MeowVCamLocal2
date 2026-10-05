#import "MMDecoder.h"
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <math.h>
#import <time.h>

@interface MMLocalWorker : NSObject
@property(nonatomic, copy) NSString *source;
@property(atomic) BOOL stop;
@property(atomic, strong) AVAssetReader *reader;
@property(nonatomic) BOOL loop;
@property(nonatomic) int edge;
@property(nonatomic) MMDecoderCallbacks callbacks;
@property(nonatomic) pthread_t thread;
@property(nonatomic) BOOL started;
- (void)run;
@end
struct MMDecoder { void *object; };
double mm_monotonic_seconds(void) {
    static mach_timebase_info_data_t info; static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return (double)mach_absolute_time() * info.numer / info.denom / 1e9;
}
static BOOL waitUntil(MMLocalWorker *w, double host) {
    while (!w.stop) {
        double remaining = host - mm_monotonic_seconds();
        if (remaining <= 0) return YES;
        struct timespec delay = {0, (long)(fmin(remaining, 0.01) * 1e9)};
        nanosleep(&delay, NULL);
    }
    return NO;
}
static void report(MMLocalWorker *w, NSString *message) {
    MMDecoderCallbacks cb = w.callbacks;
    if (cb.status) cb.status(cb.context, message.UTF8String);
}
@implementation MMLocalWorker
- (BOOL)playOnce:(double *)nextWall {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:self.source]
        options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audioTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!videoTrack || !CMTIME_IS_NUMERIC(asset.duration) || CMTimeCompare(asset.duration, kCMTimeZero) <= 0) {
        report(self, @"No readable video track or valid duration."); return NO;
    }
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) { report(self, error.localizedDescription ?: @"Reader initialization failed."); return NO; }
    self.reader = reader;
    if (self.stop) { [reader cancelReading]; self.reader = nil; return NO; }
    CGRect natural = CGRectApplyAffineTransform((CGRect){CGPointZero, videoTrack.naturalSize}, videoTrack.preferredTransform);
    if (natural.size.width < 1 || natural.size.height < 1) { self.reader = nil; return NO; }
    double factor = fmin(1, self.edge / fmax(natural.size.width, natural.size.height));
    CGSize size = CGSizeMake(fmax(2, floor(natural.size.width * factor / 2) * 2),
                             fmax(2, floor(natural.size.height * factor / 2) * 2));
    CGAffineTransform transform = videoTrack.preferredTransform;
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(-natural.origin.x, -natural.origin.y));
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(factor, factor));
    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    composition.renderSize = size;
    float fps = videoTrack.nominalFrameRate;
    if (!isfinite(fps) || fps <= 0) fps = 30;
    composition.frameDuration = CMTimeMake(1000, (int32_t)llround(fmax(1, fmin(30, fps)) * 1000));
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layer setTransform:transform atTime:kCMTimeZero];
    instruction.layerInstructions = @[layer]; composition.instructions = @[instruction];
    AVAssetReaderVideoCompositionOutput *video = [[AVAssetReaderVideoCompositionOutput alloc]
        initWithVideoTracks:@[videoTrack] videoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    video.videoComposition = composition; video.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:video]) { self.reader = nil; return NO; }
    [reader addOutput:video];
    AVAssetReaderTrackOutput *audio = nil;
    if (audioTrack) {
        NSDictionary *settings = @{AVFormatIDKey:@(kAudioFormatLinearPCM), AVSampleRateKey:@48000,
            AVNumberOfChannelsKey:@2, AVLinearPCMBitDepthKey:@32,
            AVLinearPCMIsFloatKey:@YES, AVLinearPCMIsBigEndianKey:@NO,
            AVLinearPCMIsNonInterleaved:@NO};
        audio = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:settings];
        audio.alwaysCopiesSampleData = NO;
        if ([reader canAddOutput:audio]) [reader addOutput:audio]; else audio = nil;
    }
    if (![reader startReading]) {
        report(self, reader.error.localizedDescription ?: @"Video decode failed."); self.reader = nil; return NO;
    }
    if (!audio) report(self, @"Source has no usable audio track; microphone audio remains available.");
    CMSampleBufferRef v = [video copyNextSampleBuffer];
    CMSampleBufferRef a = audio ? [audio copyNextSampleBuffer] : NULL;
    double origin = INFINITY;
    if (v) origin = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(v));
    if (a) origin = fmin(origin, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(a)));
    if (!isfinite(origin)) {
        if (v) CFRelease(v); if (a) CFRelease(a); self.reader = nil; return NO;
    }
    double wall = fmax(*nextWall, mm_monotonic_seconds() + 0.2), endWall = wall;
    MMDecoderCallbacks cb = self.callbacks;
    report(self, @"Local video and audio decoder started.");
    while (!self.stop && (v || a)) {
        @autoreleasepool {
            double vt = v ? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(v)) : INFINITY;
            double at = a ? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(a)) : INFINITY;
            BOOL takeVideo = v && (!a || vt <= at);
            double host = wall + (takeVideo ? vt : at) - origin;
            if (!isfinite(host)) { report(self, @"Invalid media timestamp."); break; }
            if (!waitUntil(self, host - 0.15)) break;
            if (takeVideo) {
                CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(v);
                double duration = CMTimeGetSeconds(CMSampleBufferGetDuration(v));
                if (!isfinite(duration) || duration <= 0) duration = CMTimeGetSeconds(composition.frameDuration);
                endWall = fmax(endWall, host + duration);
                if (pixels && host >= mm_monotonic_seconds() - 0.12 &&
                    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
                    if (cb.video) cb.video(cb.context, CVPixelBufferGetBaseAddress(pixels),
                        (int)CVPixelBufferGetWidth(pixels), (int)CVPixelBufferGetHeight(pixels),
                        (int)CVPixelBufferGetBytesPerRow(pixels), host, 0);
                    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
                }
                CFRelease(v); v = [video copyNextSampleBuffer];
            } else {
                CMBlockBufferRef data = CMSampleBufferGetDataBuffer(a);
                CMItemCount frames = CMSampleBufferGetNumSamples(a);
                float buffer[4800 * 2];
                for (CMItemCount offset = 0; data && offset < frames && !self.stop; offset += 4800) {
                    size_t n = (size_t)MIN((CMItemCount)4800, frames - offset);
                    double time = host + offset / 48000.0;
                    if (!waitUntil(self, time - 0.15)) break;
                    if (CMBlockBufferCopyDataBytes(data, (size_t)offset * 2 * sizeof(float),
                        n * 2 * sizeof(float), buffer) == kCMBlockBufferNoErr && cb.audio)
                        cb.audio(cb.context, buffer, n, time);
                    endWall = fmax(endWall, time + n / 48000.0);
                }
                CFRelease(a); a = [audio copyNextSampleBuffer];
            }
        }
    }
    if (v) CFRelease(v); if (a) CFRelease(a);
    BOOL completed = reader.status == AVAssetReaderStatusCompleted;
    if (!completed && !self.stop) report(self, reader.error.localizedDescription ?: @"Reader did not reach normal EOF.");
    [reader cancelReading]; self.reader = nil; *nextWall = endWall;
    return completed;
}
- (void)run {
    double nextWall = 0;
    while (!self.stop) {
        BOOL complete;
        @autoreleasepool { complete = [self playOnce:&nextWall]; }
        if (!complete || !self.loop) break;
    }
    if (!self.stop) {
        waitUntil(self, nextWall);
        MMDecoderCallbacks cb = self.callbacks;
        if (cb.reset) cb.reset(cb.context);
    }
    report(self, @"Local decoder stopped.");
}
@end
static void *localThread(void *context) {
    @autoreleasepool { [(__bridge MMLocalWorker *)context run]; } return NULL;
}
MMDecoder *mm_decoder_create(const char *source, int loop, int edge, MMDecoderCallbacks cb) {
    if (!source || source[0] != '/') return NULL;
    MMDecoder *d = calloc(1, sizeof(*d)); if (!d) return NULL;
    MMLocalWorker *w = [MMLocalWorker new]; w.source = [NSString stringWithUTF8String:source];
    if (!w.source) { free(d); return NULL; }
    w.loop = loop != 0; w.edge = MAX(320, MIN(edge, 1920)); w.callbacks = cb;
    d->object = (__bridge_retained void *)w; return d;
}
int mm_decoder_start(MMDecoder *d) {
    if (!d) return -1;
    MMLocalWorker *w = (__bridge MMLocalWorker *)d->object;
    if (w.started) return -1;
    pthread_t thread;
    int r = pthread_create(&thread, NULL, localThread, d->object);
    if (!r) { w.thread = thread; w.started = YES; } return r;
}
void mm_decoder_request_stop(MMDecoder *d) {
    if (!d) return;
    MMLocalWorker *w = (__bridge MMLocalWorker *)d->object;
    w.stop = YES; [w.reader cancelReading];
}
void mm_decoder_destroy(MMDecoder *d) {
    if (!d) return;
    mm_decoder_request_stop(d);
    MMLocalWorker *w = (__bridge MMLocalWorker *)d->object;
    if (w.started) pthread_join(w.thread, NULL);
    id releasedObject = CFBridgingRelease(d->object); (void)releasedObject; free(d);
}

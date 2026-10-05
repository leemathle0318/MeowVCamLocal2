#import <Foundation/Foundation.h>
#import <notify.h>
#import "../core/MMDecoder.h"
#import "../core/MMIPC.h"

static MMDecoder *decoder;
static MMIPCWriter writer;
static void videoReady(void *context, const uint8_t *pixels, int width, int height,
                       int stride, double time, double rotation) {
    (void)context; (void)rotation;
    mm_ipc_write_video(&writer, pixels, width, height, stride, time);
}
static void audioReady(void *context, const float *samples, size_t frames, double time) {
    (void)context; mm_ipc_write_audio(&writer, samples, frames, time);
}
static void decoderStatus(void *context, const char *message) {
    (void)context; @autoreleasepool { NSLog(@"[MeowVCamDecoder] %s", message); }
}
static void reload(void) {
    mm_decoder_destroy(decoder); decoder = NULL;
    mm_ipc_close(&writer.connection); writer = (MMIPCWriter){0};
    NSString *directory = @"/var/mobile/Library/Caches/MeowVCamLocal";
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0755} error:nil];
    if (mm_ipc_create(MM_IPC_PATH, &writer)) { NSLog(@"[MeowVCamDecoder] Could not create IPC transport."); return; }
    NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.meowmeow.vcam.local.plist"];
    if (![configuration[@"enabled"] boolValue]) return;
    NSString *source = configuration[@"source"];
    if (![source isKindOfClass:NSString.class] || ![source hasPrefix:@"/"] ||
        ![NSFileManager.defaultManager isReadableFileAtPath:source]) return;
    NSInteger edge = [configuration[@"videoLongEdge"] integerValue];
    if (!edge) edge = 720;
    edge = MAX(320, MIN(MM_IPC_EDGE, edge));
    MMDecoderCallbacks callbacks = {videoReady, audioReady, decoderStatus, NULL, NULL};
    decoder = mm_decoder_create(source.UTF8String, [configuration[@"loop"] boolValue], (int)edge, callbacks);
    if (!decoder || mm_decoder_start(decoder)) { mm_decoder_destroy(decoder); decoder = NULL; }
}
int main(void) {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("com.meowmeow.local.decoder.control", DISPATCH_QUEUE_SERIAL);
        int token;
        notify_register_dispatch("com.meowmeow.vcam.local.changed", &token, queue, ^(int t) {
            (void)t; @autoreleasepool { reload(); }
        });
        dispatch_async(queue, ^{ @autoreleasepool { reload(); } });
        dispatch_main();
    }
    return 0;
}

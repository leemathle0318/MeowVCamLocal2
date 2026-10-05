#include "MMDecoder.h"
#include "MMIPC.h"
#include <stdatomic.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <time.h>
#include <math.h>

struct MMDecoder {
    atomic_bool stop;
    int started;
    pthread_t thread;
    MMDecoderCallbacks callbacks;
};
static mach_timebase_info_data_t clockInfo;
static pthread_once_t clockOnce = PTHREAD_ONCE_INIT;
static void initializeClock(void) { mach_timebase_info(&clockInfo); }
double mm_monotonic_seconds(void) {
    pthread_once(&clockOnce, initializeClock);
    return (double)mach_absolute_time() * clockInfo.numer / clockInfo.denom / 1e9;
}
static void *receiveMedia(void *context) {
    MMDecoder *decoder = context;
    MMDecoderCallbacks cb = decoder->callbacks;
    MMIPCConnection connection = {.fd = -1};
    struct stat mappedFile = {0};
    uint64_t videos[MM_IPC_VIDEO_SLOTS] = {0}, audio[MM_IPC_AUDIO_SLOTS] = {0};
    uint8_t *pixels = malloc(MM_IPC_VIDEO_BYTES);
    float samples[MM_IPC_AUDIO_FRAMES * 2];
    double checkAfter = 0;
    if (!pixels) { if (cb.status) cb.status(cb.context, "IPC receiver allocation failed."); return NULL; }
    while (!atomic_load(&decoder->stop)) {
        double now = mm_monotonic_seconds();
        if (now >= checkAfter) {
            struct stat current;
            checkAfter = now + 0.25;
            if (!stat(MM_IPC_PATH, &current) && (!connection.shared || current.st_ino != mappedFile.st_ino || current.st_dev != mappedFile.st_dev)) {
                MMIPCConnection fresh = {.fd = -1};
                if (!mm_ipc_open(MM_IPC_PATH, &fresh)) {
                    mm_ipc_close(&connection); connection = fresh; mappedFile = current;
                    memset(videos, 0, sizeof(videos)); memset(audio, 0, sizeof(audio));
                    if (cb.reset) cb.reset(cb.context);
                    if (cb.status) cb.status(cb.context, "Connected to the separate decoder helper.");
                }
            }
        }
        if (connection.shared) {
            for (unsigned i = 0; i < MM_IPC_VIDEO_SLOTS && !atomic_load(&decoder->stop); i++) {
                MMIPCVideo *slot = &connection.shared->video[i];
                if (mm_ipc_trylock(&connection, i)) continue;
                int width = slot->width, height = slot->height, stride = slot->stride;
                double time = slot->time;
                int fresh = slot->sequence && slot->sequence != videos[i] && width > 0 && height > 0 &&
                    width <= MM_IPC_EDGE && height <= MM_IPC_EDGE && stride == width * 4 &&
                    isfinite(time) && time >= now - 0.25;
                if (fresh) memcpy(pixels, slot->data, (size_t)stride * height);
                videos[i] = slot->sequence;
                mm_ipc_unlock(&connection, i);
                if (fresh && cb.video) cb.video(cb.context, pixels, width, height, stride, time, 0);
            }
            for (unsigned i = 0; i < MM_IPC_AUDIO_SLOTS && !atomic_load(&decoder->stop); i++) {
                MMIPCAudio *slot = &connection.shared->audio[i];
                if (mm_ipc_trylock(&connection, MM_IPC_VIDEO_SLOTS + i)) continue;
                size_t count = slot->frames; double time = slot->time;
                int fresh = slot->sequence && slot->sequence != audio[i] && count > 0 && count <= MM_IPC_AUDIO_FRAMES &&
                    isfinite(time) && time >= now - 0.25;
                if (fresh) memcpy(samples, slot->data, count * 2 * sizeof(float));
                audio[i] = slot->sequence;
                mm_ipc_unlock(&connection, MM_IPC_VIDEO_SLOTS + i);
                if (fresh && cb.audio) cb.audio(cb.context, samples, count, time);
            }
        }
        struct timespec delay = {0, 4000000}; nanosleep(&delay, NULL);
    }
    mm_ipc_close(&connection); free(pixels); return NULL;
}
MMDecoder *mm_decoder_create(const char *source, int loop, int edge, MMDecoderCallbacks callbacks) {
    (void)loop; (void)edge;
    if (!source || source[0] != '/') return NULL;
    MMDecoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder) { atomic_init(&decoder->stop, 0); decoder->callbacks = callbacks; }
    return decoder;
}
int mm_decoder_start(MMDecoder *decoder) {
    if (!decoder || decoder->started) return -1;
    int result = pthread_create(&decoder->thread, NULL, receiveMedia, decoder);
    if (!result) decoder->started = 1;
    return result;
}
void mm_decoder_request_stop(MMDecoder *decoder) { if (decoder) atomic_store(&decoder->stop, 1); }
void mm_decoder_destroy(MMDecoder *decoder) {
    if (!decoder) return;
    mm_decoder_request_stop(decoder);
    if (decoder->started) pthread_join(decoder->thread, NULL);
    free(decoder);
}

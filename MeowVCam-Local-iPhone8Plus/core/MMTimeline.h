#ifndef MM_TIMELINE_H
#define MM_TIMELINE_H
#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#ifdef __cplusplus
extern "C" {
#endif
#define MM_PCM_RATE 48000
#define MM_PCM_FRAMES (MM_PCM_RATE * 2)
/* Fixed two-second stereo cache, indexed by absolute monotonic sample time.
 * Readers do not consume samples; two capture clients can read the same time. */
typedef struct {
    pthread_mutex_t lock;
    float pcm[MM_PCM_FRAMES][2];
    int64_t tags[MM_PCM_FRAMES];
} MMPCMCache;
int mm_pcm_init(MMPCMCache *cache);
void mm_pcm_destroy(MMPCMCache *cache);
void mm_pcm_clear(MMPCMCache *cache);
void mm_pcm_write(MMPCMCache *cache, double hostSeconds,
                  const float *stereo, size_t frames);
/* Returns number of frames for which data existed. Missing samples are zero.
 * A busy writer causes silence, never waiting on the real-time audio thread. */
size_t mm_pcm_read(MMPCMCache *cache, double hostSeconds, double rate,
                   unsigned channels, float *out, size_t frames);
#ifdef __cplusplus
}
#endif
#endif

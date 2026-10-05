#include "../core/MMTimeline.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

static MMPCMCache cache;
static void near(float a, float b) {
    if (fabsf(a - b) >= 0.0002f) fprintf(stderr, "Expected %.7f, received %.7f\n", b, a);
    assert(fabsf(a - b) < 0.0002f);
}
static void *writer(void *ignored) {
    (void)ignored;
    float pcm[480 * 2];
    for (size_t i = 0; i < 480; i++) { pcm[i * 2] = 0.25f; pcm[i * 2 + 1] = -0.25f; }
    for (int n = 0; n < 1000; n++) mm_pcm_write(&cache, 50000 + n * 0.01, pcm, 480);
    return NULL;
}
int main(void) {
    assert(mm_pcm_init(&cache) == 0);
    float out[480 * 2];
    assert(mm_pcm_read(&cache, 100, 48000, 2, out, 480) == 0);
    for (size_t i = 0; i < 960; i++) near(out[i], 0);
    float source[481 * 2];
    for (size_t i = 0; i < 481; i++) { source[i * 2] = i * 0.001f; source[i * 2 + 1] = -(float)i * 0.0005f; }
    /* Indexing far beyond 32-bit samples: about 11.6 days monotonic uptime. */
    double t = 1000000;
    mm_pcm_write(&cache, t, source, 481);
    assert(mm_pcm_read(&cache, t, 48000, 2, out, 480) == 480);
    for (size_t i = 0; i < 480; i++) { near(out[i * 2], source[i * 2]); near(out[i * 2 + 1], source[i * 2 + 1]); }
    /* Reading a second time does not consume audio or move playback. */
    assert(mm_pcm_read(&cache, t, 48000, 2, out, 480) == 480);
    assert(mm_pcm_read(&cache, t, 24000, 1, out, 200) == 200);
    for (size_t i = 0; i < 200; i++) near(out[i], i * 0.0005f);
    assert(mm_pcm_read(&cache, t + 0.5 / 48000, 48000, 2, out, 200) == 200);
    near(out[0], 0.0005f); near(out[1], -0.00025f);
    mm_pcm_write(&cache, t + 2, source, 481);
    assert(mm_pcm_read(&cache, t, 48000, 2, out, 200) == 0);
    assert(mm_pcm_read(&cache, t + 2, 48000, 2, out, 200) == 200);
    pthread_mutex_lock(&cache.lock);
    assert(mm_pcm_read(&cache, t + 2, 48000, 2, out, 200) == 0);
    pthread_mutex_unlock(&cache.lock);
    mm_pcm_clear(&cache);
    assert(mm_pcm_read(&cache, t + 2, 48000, 2, out, 200) == 0);
    assert(mm_pcm_read(&cache, NAN, 48000, 2, out, 200) == 0);
    pthread_t thread; assert(pthread_create(&thread, NULL, writer, NULL) == 0);
    for (int n = 0; n < 1000; n++) {
        mm_pcm_read(&cache, 50000 + n * 0.01, 48000, 2, out, 480);
        for (size_t i = 0; i < 960; i++) assert(isfinite(out[i]) && fabsf(out[i]) <= 0.2501f);
    }
    pthread_join(thread, NULL);
    mm_pcm_destroy(&cache);
    printf("PCM checks passed: 64-bit timing, stereo/mono, rate conversion, reuse, overwrite, underflow, concurrent access.\n");
    return 0;
}

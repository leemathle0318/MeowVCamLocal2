#include "../core/MMAudioMix.h"
#include "../core/MMTimeline.h"
#include <assert.h>
#include <math.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>

static void near(float actual, float expected) { assert(fabsf(actual - expected) < 0.00001f); }
int main(void) {
    near(mm_audio_mix_float(0.125f, 0.25f), 0.375f);
    near(mm_audio_mix_float(0.4f, -0.4f), 0);
    assert(mm_audio_mix_s16(8192, 0.25f) == 16384);
    assert(mm_audio_mix_s16(32760, 0.5f) == INT16_MAX);
    assert(mm_audio_mix_s16(-32760, -0.5f) == INT16_MIN);
    near(mm_audio_mix_float(0.8f, 0.8f), 1);
    near(mm_audio_mix_float(-0.8f, -0.8f), -1);
    near(mm_audio_mix_float(0.3f, NAN), 0.3f);
    near(mm_audio_mix_float(NAN, 0.3f), 0.3f);
    for (int value = INT16_MIN; value <= INT16_MAX; value++)
        assert(mm_audio_mix_s16((int16_t)value, 0) == value);

    MMPCMCache *cache = calloc(1, sizeof(*cache)); assert(cache && mm_pcm_init(cache) == 0);
    float video[16], scratch[8];
    for (unsigned i = 0; i < 8; i++) { video[i * 2] = 0.2f; video[i * 2 + 1] = 0.6f; }
    mm_pcm_write(cache, 100, video, 8);
    assert(mm_pcm_read(cache, 100, 48000, 2, scratch, 4) == 4);
    near(mm_audio_mix_float(0.1f, scratch[0]), 0.3f);
    near(mm_audio_mix_float(-0.1f, scratch[1]), 0.5f);
    assert(mm_pcm_read(cache, 100, 24000, 1, scratch, 4) == 4);
    near(mm_audio_mix_float(0.1f, scratch[0]), 0.5f);

    // During video underflow or a busy writer the real microphone remains.
    assert(mm_pcm_read(cache, 102, 48000, 1, scratch, 4) == 0);
    for (unsigned i = 0; i < 4; i++) assert(mm_audio_mix_s16(-12345, scratch[i]) == -12345);
    assert(pthread_mutex_lock(&cache->lock) == 0);
    assert(mm_pcm_read(cache, 100, 48000, 1, scratch, 4) == 0);
    assert(pthread_mutex_unlock(&cache->lock) == 0);
    for (unsigned i = 0; i < 4; i++) near(mm_audio_mix_float(0.25f, scratch[i]), 0.25f);
    mm_pcm_clear(cache);
    assert(mm_pcm_read(cache, 100, 48000, 1, scratch, 4) == 0);
    near(mm_audio_mix_float(0.25f, scratch[0]), 0.25f);
    mm_pcm_destroy(cache); free(cache);
    puts("Audio mix checks passed: both sources, all silent-video int16 values, clipping, mono/stereo rate conversion, video underflow and busy-cache microphone continuity.");
    return 0;
}

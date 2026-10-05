#include "MMAudioMix.h"
#include <math.h>
#include <limits.h>

float mm_audio_mix_float(float microphone, float video) {
    if (!isfinite(microphone)) microphone = 0;
    if (!isfinite(video)) video = 0;
    if (video == 0) return microphone;
    return fmaxf(-1, fminf(1, microphone + video));
}
int16_t mm_audio_mix_s16(int16_t microphone, float video) {
    if (!isfinite(video) || video == 0) return microphone;
    float mixed = mm_audio_mix_float(microphone / 32768.0f, video);
    long value = lrintf(mixed * 32768.0f);
    if (value > INT16_MAX) return INT16_MAX;
    if (value < INT16_MIN) return INT16_MIN;
    return (int16_t)value;
}

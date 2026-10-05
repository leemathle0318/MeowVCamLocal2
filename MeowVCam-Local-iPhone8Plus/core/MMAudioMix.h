#ifndef MM_AUDIO_MIX_H
#define MM_AUDIO_MIX_H
#include <stdint.h>
/* Add video PCM to the original microphone sample, retaining unit gain for
 * each source. Saturate peaks so integer PCM never wraps on overflow. */
float mm_audio_mix_float(float microphone, float video);
int16_t mm_audio_mix_s16(int16_t microphone, float video);
#endif

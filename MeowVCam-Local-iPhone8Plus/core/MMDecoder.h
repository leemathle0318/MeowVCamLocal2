#ifndef MM_DECODER_H
#define MM_DECODER_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MMDecoder MMDecoder;
typedef struct {
    void (*video)(void *, const uint8_t *bgra, int width, int height,
                  int stride, double hostSeconds, double rotationDegrees);
    void (*audio)(void *, const float *stereo, size_t frames, double hostSeconds);
    void (*status)(void *, const char *message);
    void (*reset)(void *);
    void *context;
} MMDecoderCallbacks;
/* Local file path only. Copies the source string, no whole-file preload.
 * Callbacks are made on the decoder worker; supplied memory is transient. */
MMDecoder *mm_decoder_create(const char *source, int loop, int longEdge,
                             MMDecoderCallbacks callbacks);
int mm_decoder_start(MMDecoder *decoder);
void mm_decoder_request_stop(MMDecoder *decoder);
/* Never call destroy on a camera/audio callback: waits for decoder worker. */
void mm_decoder_destroy(MMDecoder *decoder);
double mm_monotonic_seconds(void);
#ifdef __cplusplus
}
#endif
#endif

#include "MMTimeline.h"
#include <math.h>
#include <string.h>
#include <limits.h>
static size_t slot(int64_t n) {
    int64_t r = n % MM_PCM_FRAMES;
    return (size_t)(r < 0 ? r + MM_PCM_FRAMES : r);
}
int mm_pcm_init(MMPCMCache *c) {
    int r = pthread_mutex_init(&c->lock, NULL);
    if (r) return r;
    mm_pcm_clear(c);
    return 0;
}
void mm_pcm_destroy(MMPCMCache *c) { pthread_mutex_destroy(&c->lock); }
void mm_pcm_clear(MMPCMCache *c) {
    pthread_mutex_lock(&c->lock);
    for (size_t i = 0; i < MM_PCM_FRAMES; i++) c->tags[i] = INT64_MIN;
    pthread_mutex_unlock(&c->lock);
}
void mm_pcm_write(MMPCMCache *c, double seconds, const float *p, size_t n) {
    if (!isfinite(seconds) || !p || seconds < 0 || seconds > 1e10) return;
    int64_t base = (int64_t)llround(seconds * MM_PCM_RATE);
    pthread_mutex_lock(&c->lock);
    /* Preserve only the last two seconds if a decoder produces a huge block. */
    size_t first = n > MM_PCM_FRAMES ? n - MM_PCM_FRAMES : 0;
    for (size_t i = first; i < n; i++) {
        int64_t t = base + (int64_t)i;
        size_t s = slot(t);
        c->pcm[s][0] = p[i * 2]; c->pcm[s][1] = p[i * 2 + 1];
        c->tags[s] = t;
    }
    pthread_mutex_unlock(&c->lock);
}
size_t mm_pcm_read(MMPCMCache *c, double seconds, double rate,
                  unsigned ch, float *out, size_t n) {
    if (!out || ch < 1 || ch > 2) return 0;
    memset(out, 0, n * ch * sizeof(float));
    if (!isfinite(seconds) || seconds < 0 || seconds > 1e10 ||
        !isfinite(rate) || rate < 8000 || rate > 192000) return 0;
    if (pthread_mutex_trylock(&c->lock)) return 0;
    size_t found = 0;
    double base = seconds * MM_PCM_RATE, step = MM_PCM_RATE / rate;
    for (size_t i = 0; i < n; i++) {
        double x = base + i * step;
        int64_t a = (int64_t)floor(x);
        size_t sa = slot(a), sb = slot(a + 1);
        if (c->tags[sa] != a) continue;
        double fraction = x - a;
        float l = c->pcm[sa][0], r = c->pcm[sa][1];
        if (c->tags[sb] == a + 1) {
            l += (c->pcm[sb][0] - l) * fraction;
            r += (c->pcm[sb][1] - r) * fraction;
        }
        if (ch == 1) out[i] = (l + r) * 0.5f;
        else { out[i * 2] = l; out[i * 2 + 1] = r; }
        found++;
    }
    pthread_mutex_unlock(&c->lock);
    return found;
}

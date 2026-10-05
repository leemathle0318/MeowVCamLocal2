#ifndef MM_IPC_H
#define MM_IPC_H
#include <stdint.h>
#include <stddef.h>

/* Fixed-size media transport, shared by the decoder helper and capture hook.
 * Slot ownership uses nonblocking POSIX record locks. The kernel releases them
 * if a process exits. One producer thread and one receiver thread are required.
 * A helper restart or source change publishes a new inode.
 */
#define MM_IPC_PATH "/var/mobile/Library/Caches/MeowVCamLocal/frames-v3.bin"
#define MM_IPC_MAGIC UINT32_C(0x4d4d4933)
#define MM_IPC_VIDEO_SLOTS 6
#define MM_IPC_AUDIO_SLOTS 16
#define MM_IPC_EDGE 1280
#define MM_IPC_VIDEO_BYTES (MM_IPC_EDGE * MM_IPC_EDGE * 4)
#define MM_IPC_AUDIO_FRAMES 4800

typedef struct {
    uint64_t sequence;
    double time;
    int width, height, stride;
    uint8_t data[MM_IPC_VIDEO_BYTES];
} MMIPCVideo;
typedef struct {
    uint64_t sequence;
    double time;
    size_t frames;
    float data[MM_IPC_AUDIO_FRAMES * 2];
} MMIPCAudio;
typedef struct {
    uint32_t magic, version;
    MMIPCVideo video[MM_IPC_VIDEO_SLOTS];
    MMIPCAudio audio[MM_IPC_AUDIO_SLOTS];
} MMIPCShared;
typedef struct {
    MMIPCShared *shared;
    int fd;
    int writable;
} MMIPCConnection;
typedef struct {
    MMIPCConnection connection;
    uint64_t sequence;
    unsigned videoCursor, audioCursor;
} MMIPCWriter;

int mm_ipc_create(const char *path, MMIPCWriter *writer);
int mm_ipc_open(const char *path, MMIPCConnection *connection);
void mm_ipc_close(MMIPCConnection *connection);
int mm_ipc_trylock(MMIPCConnection *connection, unsigned slot);
void mm_ipc_unlock(MMIPCConnection *connection, unsigned slot);
int mm_ipc_write_video(MMIPCWriter *writer, const uint8_t *pixels,
                       int width, int height, int stride, double time);
int mm_ipc_write_audio(MMIPCWriter *writer, const float *samples, size_t frames, double time);
#endif

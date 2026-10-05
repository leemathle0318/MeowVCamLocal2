#define _POSIX_C_SOURCE 200809L
#include "MMIPC.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

void mm_ipc_close(MMIPCConnection *connection) {
    if (!connection) return;
    if (connection->shared) { munmap(connection->shared, sizeof(*connection->shared)); close(connection->fd); }
    *connection = (MMIPCConnection){.fd = -1};
}
int mm_ipc_trylock(MMIPCConnection *connection, unsigned slot) {
    if (!connection || !connection->shared || slot >= MM_IPC_VIDEO_SLOTS + MM_IPC_AUDIO_SLOTS) return -1;
    struct flock lock = {.l_type = connection->writable ? F_WRLCK : F_RDLCK,
        .l_whence = SEEK_SET, .l_start = (off_t)slot + 1, .l_len = 1};
    return fcntl(connection->fd, F_SETLK, &lock);
}
void mm_ipc_unlock(MMIPCConnection *connection, unsigned slot) {
    struct flock lock = {.l_type = F_UNLCK, .l_whence = SEEK_SET, .l_start = (off_t)slot + 1, .l_len = 1};
    (void)fcntl(connection->fd, F_SETLK, &lock);
}
int mm_ipc_create(const char *path, MMIPCWriter *writer) {
    if (!path || !writer) return -1;
    char *temporary = malloc(strlen(path) + 12);
    if (!temporary) return -1;
    sprintf(temporary, "%s.XXXXXX", path);
    int fd = mkstemp(temporary), ok = 0;
    MMIPCShared *shared = NULL;
    if (fd < 0) { free(temporary); return -1; }
    if (ftruncate(fd, sizeof(MMIPCShared))) goto cleanup;
    if (fchmod(fd, 0644)) goto cleanup;
    shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shared == MAP_FAILED) { shared = NULL; goto cleanup; }
    /* New zero-filled inode is fully initialized before publication. */
    shared->version = 3; shared->magic = MM_IPC_MAGIC;
    if (rename(temporary, path)) goto cleanup;
    *writer = (MMIPCWriter){.connection = {.shared = shared, .fd = fd, .writable = 1}}; ok = 1;
cleanup:
    if (!ok) { if (shared) munmap(shared, sizeof(*shared)); close(fd); unlink(temporary); }
    free(temporary); return ok ? 0 : -1;
}
int mm_ipc_open(const char *path, MMIPCConnection *connection) {
    if (!connection) return -1;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) || info.st_size != (off_t)sizeof(MMIPCShared)) { close(fd); return -1; }
    MMIPCShared *shared = mmap(NULL, sizeof(*shared), PROT_READ, MAP_SHARED, fd, 0);
    if (shared == MAP_FAILED) { close(fd); return -1; }
    if (shared->magic != MM_IPC_MAGIC || shared->version != 3) {
        munmap(shared, sizeof(*shared)); close(fd); return -1;
    }
    *connection = (MMIPCConnection){.shared = shared, .fd = fd}; return 0;
}
int mm_ipc_write_video(MMIPCWriter *writer, const uint8_t *pixels,
                       int width, int height, int stride, double time) {
    if (!writer || !writer->connection.shared || !pixels || !isfinite(time) ||
        width < 1 || height < 1 || width > MM_IPC_EDGE || height > MM_IPC_EDGE || stride < width * 4) return -1;
    for (unsigned tries = 0; tries < MM_IPC_VIDEO_SLOTS; tries++) {
        unsigned index = writer->videoCursor++ % MM_IPC_VIDEO_SLOTS;
        MMIPCVideo *slot = &writer->connection.shared->video[index];
        if (mm_ipc_trylock(&writer->connection, index)) continue;
        slot->width = width; slot->height = height; slot->stride = width * 4; slot->time = time;
        for (int y = 0; y < height; y++)
            memcpy(slot->data + (size_t)y * width * 4, pixels + (size_t)y * stride, (size_t)width * 4);
        slot->sequence = ++writer->sequence;
        mm_ipc_unlock(&writer->connection, index); return 0;
    }
    return 1; /* Slow/dead reader: drop this frame instead of blocking. */
}
int mm_ipc_write_audio(MMIPCWriter *writer, const float *samples, size_t frames, double time) {
    if (!writer || !writer->connection.shared || !samples || !isfinite(time) || !frames || frames > MM_IPC_AUDIO_FRAMES) return -1;
    for (unsigned tries = 0; tries < MM_IPC_AUDIO_SLOTS; tries++) {
        unsigned index = writer->audioCursor++ % MM_IPC_AUDIO_SLOTS;
        MMIPCAudio *slot = &writer->connection.shared->audio[index];
        if (mm_ipc_trylock(&writer->connection, MM_IPC_VIDEO_SLOTS + index)) continue;
        memcpy(slot->data, samples, frames * 2 * sizeof(float));
        slot->frames = frames; slot->time = time; slot->sequence = ++writer->sequence;
        mm_ipc_unlock(&writer->connection, MM_IPC_VIDEO_SLOTS + index); return 0;
    }
    return 1;
}

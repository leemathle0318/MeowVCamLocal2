#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "../core/MMIPC.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>

int main(void) {
    char directory[] = "/tmp/meowvcam-ipc-XXXXXX";
    assert(mkdtemp(directory));
    char path[256]; snprintf(path, sizeof(path), "%s/frames.bin", directory);
    MMIPCWriter writer = {0};
    assert(mm_ipc_create(path, &writer) == 0);
    uint8_t pixels[4 * 4 * 4]; memset(pixels, 0x5a, sizeof(pixels));
    float audio[8] = {0.25f, -0.25f, 0.5f, -0.5f, 1, -1, 0, 0};
    assert(mm_ipc_write_video(&writer, pixels, 4, 4, 16, 100) == 0);
    assert(mm_ipc_write_audio(&writer, audio, 4, 100) == 0);
    assert(mm_ipc_write_video(&writer, pixels, MM_IPC_EDGE + 1, 4, 16, 100) == -1);
    assert(mm_ipc_write_audio(&writer, audio, MM_IPC_AUDIO_FRAMES + 1, 100) == -1);
    int ready[2], exitChild[2]; assert(pipe(ready) == 0 && pipe(exitChild) == 0);
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        close(ready[0]); close(exitChild[1]);
        mm_ipc_close(&writer.connection);
        MMIPCConnection reader = {.fd = -1}; assert(mm_ipc_open(path, &reader) == 0);
        assert(mm_ipc_trylock(&reader, 0) == 0);
        assert(reader.shared->video[0].width == 4 && reader.shared->video[0].time == 100);
        assert(memcmp(reader.shared->video[0].data, pixels, sizeof(pixels)) == 0);
        mm_ipc_unlock(&reader, 0);
        assert(mm_ipc_trylock(&reader, MM_IPC_VIDEO_SLOTS) == 0);
        assert(reader.shared->audio[0].frames == 4 && memcmp(reader.shared->audio[0].data, audio, sizeof(audio)) == 0);
        mm_ipc_unlock(&reader, MM_IPC_VIDEO_SLOTS);
        for (unsigned i = 0; i < MM_IPC_VIDEO_SLOTS; i++) assert(mm_ipc_trylock(&reader, i) == 0);
        char signal = 'L'; assert(write(ready[1], &signal, 1) == 1);
        assert(read(exitChild[0], &signal, 1) == 1);
        // Deliberately exit without unlocking: kernel must release ownership.
        _exit(0);
    }
    close(ready[1]); close(exitChild[0]);
    char signal; assert(read(ready[0], &signal, 1) == 1);
    assert(mm_ipc_write_video(&writer, pixels, 4, 4, 16, 101) == 1);
    assert(write(exitChild[1], "X", 1) == 1);
    int status; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(mm_ipc_write_video(&writer, pixels, 4, 4, 16, 102) == 0);
    close(ready[0]); close(exitChild[1]);
    MMIPCConnection oldReader = {.fd = -1}; assert(mm_ipc_open(path, &oldReader) == 0);
    struct stat oldFile, newFile; assert(stat(path, &oldFile) == 0);
    mm_ipc_close(&writer.connection);
    assert(mm_ipc_create(path, &writer) == 0 && stat(path, &newFile) == 0);
    assert(oldFile.st_ino != newFile.st_ino);
    assert(writer.connection.shared->video[0].sequence == 0);
    assert(oldReader.shared->video[0].sequence != 0);
    mm_ipc_close(&oldReader); mm_ipc_close(&writer.connection);
    assert(unlink(path) == 0 && rmdir(directory) == 0);
    puts("IPC checks passed: cross-process audio/video, bounded payloads, nonblocking drop, process-exit lock release, source/restart inode isolation.");
    return 0;
}

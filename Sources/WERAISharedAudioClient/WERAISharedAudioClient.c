#include "WERAISharedAudioClient.h"
#include <fcntl.h>
#include <pwd.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define WERAI_NAME "/alo-audio-frames-v2"
#define WERAI_MAGIC UINT64_C(0x5745524149415544)
#define WERAI_VERSION 2u
#define WERAI_CHANNELS 2u
#define WERAI_CAPACITY 32768u
#define WERAI_SAFETY_FRAMES 256u
#define WERAI_IN_PROGRESS UINT64_MAX

typedef struct { uint64_t sequence, samplePosition, hostTime; uint32_t sampleBits[2]; } Frame;
typedef struct {
    uint64_t magic;
    uint32_t version, headerSize, sampleRate, channels, capacityFrames, reserved;
    uint64_t generation, latestFrameExclusive;
    Frame frames[WERAI_CAPACITY];
} Buffer;

WERAISharedAudioHandle WERAISharedAudioClientOpen(void) {
    int descriptor = shm_open(WERAI_NAME, O_RDONLY, 0);
    if (descriptor < 0) return NULL;
    (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    struct stat status;
    struct passwd *coreAudio = getpwnam("_coreaudiod");
    size_t pageSize = (size_t)getpagesize();
    off_t canonicalSize = (off_t)((sizeof(Buffer) + pageSize - 1) / pageSize * pageSize);
    if (fstat(descriptor, &status) != 0 || S_ISDIR(status.st_mode) ||
        status.st_size != canonicalSize ||
        (status.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
        !(status.st_uid == geteuid() || status.st_uid == 0 ||
          (coreAudio != NULL && status.st_uid == coreAudio->pw_uid))) {
        close(descriptor);
        return NULL;
    }
    void *mapping = mmap(NULL, sizeof(Buffer), PROT_READ, MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) return NULL;
    Buffer *buffer = mapping;
    atomic_thread_fence(memory_order_acquire);
    if (buffer->magic != WERAI_MAGIC || buffer->version != WERAI_VERSION ||
        buffer->headerSize != offsetof(Buffer, frames) || buffer->sampleRate != 48000 ||
        buffer->channels != WERAI_CHANNELS || buffer->capacityFrames != WERAI_CAPACITY) {
        munmap(mapping, sizeof(Buffer));
        return NULL;
    }
    return mapping;
}

void WERAISharedAudioClientClose(WERAISharedAudioHandle handle) {
    if (handle != NULL) munmap(handle, sizeof(Buffer));
}
uint64_t WERAISharedAudioClientGeneration(WERAISharedAudioHandle handle) {
    if (handle == NULL) return 0;
    atomic_thread_fence(memory_order_acquire);
    return __atomic_load_n(&((Buffer *)handle)->generation, __ATOMIC_ACQUIRE);
}
uint64_t WERAISharedAudioClientLatestFrame(WERAISharedAudioHandle handle) {
    if (handle == NULL) return 0;
    uint64_t latest = __atomic_load_n(&((Buffer *)handle)->latestFrameExclusive, __ATOMIC_ACQUIRE);
    return latest > WERAI_SAFETY_FRAMES ? latest - WERAI_SAFETY_FRAMES : 0;
}
int WERAISharedAudioClientRead(WERAISharedAudioHandle handle, uint64_t position,
                               float samples[2], uint64_t *hostTime) {
    if (handle == NULL) return 0;
    if (position >= WERAISharedAudioClientLatestFrame(handle)) return 0;
    Frame *slot = &((Buffer *)handle)->frames[position % WERAI_CAPACITY];
    uint64_t first = __atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE);
    if (first == WERAI_IN_PROGRESS || first != position + 1) return 0;
    uint32_t leftBits = __atomic_load_n(&slot->sampleBits[0], __ATOMIC_RELAXED);
    uint32_t rightBits = __atomic_load_n(&slot->sampleBits[1], __ATOMIC_RELAXED);
    uint64_t timestamp = __atomic_load_n(&slot->hostTime, __ATOMIC_RELAXED);
    uint64_t second = __atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE);
    if (first != second || second == WERAI_IN_PROGRESS ||
        __atomic_load_n(&slot->samplePosition, __ATOMIC_RELAXED) != position) return 0;
    memcpy(&samples[0], &leftBits, sizeof(leftBits));
    memcpy(&samples[1], &rightBits, sizeof(rightBits));
    if (hostTime != NULL) *hostTime = timestamp;
    return 1;
}

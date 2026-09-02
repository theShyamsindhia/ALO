// Copyright (c) 2026 WERAI contributors. MIT licensed.
#include "WERAISharedAudio.h"
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const size_t kSharedSize = sizeof(WERAISharedAudioBuffer);

// The HAL process runs as _coreaudiod while ALO runs as the login user. A 0644
// object is the narrowest mode that permits this read-only handoff without an
// authenticated IPC broker. Consequently, another local account can read the
// ring while it exists; the object is never group/world writable, and both ends
// validate its owner, type, exact size, mode, and ABI before mapping it.

static bool validObject(const struct stat *status, bool producer) {
    // Darwin reports no portable file-type bits for POSIX shm descriptors
    // (`S_TYPEISSHM` is defined as 0), so exact size/owner/mode are the useful checks.
    size_t pageSize = (size_t)getpagesize();
    off_t canonicalSize = (off_t)((kSharedSize + pageSize - 1) / pageSize * pageSize);
    if (S_ISDIR(status->st_mode) || status->st_size != canonicalSize) return false;
    if ((status->st_mode & (S_IWGRP | S_IWOTH)) != 0) return false;
    if (producer) return status->st_uid == geteuid();
    struct passwd *coreAudio = getpwnam("_coreaudiod");
    return status->st_uid == geteuid() || status->st_uid == 0 ||
           (coreAudio != NULL && status->st_uid == coreAudio->pw_uid);
}

static WERAISharedAudioBuffer *mapProducer(void) {
    bool created = false;
    int descriptor = shm_open(WERAI_SHARED_AUDIO_NAME, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (descriptor >= 0) {
        created = true;
        // Darwin's POSIX shm implementation rejects fchmod; the creation mode is
        // therefore authoritative (subject to coreaudiod's non-permissive umask).
        if (ftruncate(descriptor, (off_t)kSharedSize) != 0) {
            close(descriptor);
            shm_unlink(WERAI_SHARED_AUDIO_NAME);
            return NULL;
        }
    } else if (errno == EEXIST) {
        descriptor = shm_open(WERAI_SHARED_AUDIO_NAME, O_RDWR, 0);
    }
    if (descriptor < 0) return NULL;
    (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    struct stat status;
    if (fstat(descriptor, &status) != 0 || !validObject(&status, true)) {
        close(descriptor);
        if (created) shm_unlink(WERAI_SHARED_AUDIO_NAME);
        return NULL;
    }
    void *mapping = mmap(NULL, kSharedSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) return NULL;
    return mapping;
}

static WERAISharedAudioBuffer *mapConsumer(void) {
    int descriptor = shm_open(WERAI_SHARED_AUDIO_NAME, O_RDONLY, 0);
    if (descriptor < 0) return NULL;
    (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    struct stat status;
    if (fstat(descriptor, &status) != 0 || !validObject(&status, false)) {
        close(descriptor);
        return NULL;
    }
    void *mapping = mmap(NULL, kSharedSize, PROT_READ, MAP_SHARED, descriptor, 0);
    close(descriptor);
    return mapping == MAP_FAILED ? NULL : mapping;
}

WERAISharedAudioBuffer *WERAISharedAudioCreateProducer(void) {
    WERAISharedAudioBuffer *buffer = mapProducer();
    if (buffer == NULL) return NULL;
    uint64_t nextGeneration = buffer->magic == WERAI_SHARED_AUDIO_MAGIC
        ? __atomic_load_n(&buffer->generation, __ATOMIC_ACQUIRE) + 1 : 1;
    memset(buffer, 0, kSharedSize);
    buffer->magic = WERAI_SHARED_AUDIO_MAGIC;
    buffer->version = WERAI_SHARED_AUDIO_VERSION;
    buffer->headerSize = (uint32_t)__builtin_offsetof(WERAISharedAudioBuffer, frames);
    buffer->sampleRate = 48000;
    buffer->channels = WERAI_SHARED_AUDIO_CHANNELS;
    buffer->capacityFrames = WERAI_SHARED_AUDIO_CAPACITY_FRAMES;
    __atomic_store_n(&buffer->generation, nextGeneration, __ATOMIC_RELEASE);
    atomic_thread_fence(memory_order_release);
    return buffer;
}

WERAISharedAudioBuffer *WERAISharedAudioOpenConsumer(void) {
    WERAISharedAudioBuffer *buffer = mapConsumer();
    if (buffer == NULL) return NULL;
    atomic_thread_fence(memory_order_acquire);
    if (buffer->magic != WERAI_SHARED_AUDIO_MAGIC ||
        buffer->version != WERAI_SHARED_AUDIO_VERSION ||
        buffer->capacityFrames != WERAI_SHARED_AUDIO_CAPACITY_FRAMES) {
        WERAISharedAudioClose(buffer);
        return NULL;
    }
    return buffer;
}

void WERAISharedAudioClose(WERAISharedAudioBuffer *buffer) {
    if (buffer != NULL) munmap(buffer, kSharedSize);
}

void WERAISharedAudioPublish(WERAISharedAudioBuffer *buffer, uint64_t firstFrame,
                             uint64_t firstHostTime, double hostTicksPerFrame,
                             const float *samples, uint32_t frameCount) {
    if (buffer == NULL) return;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        uint64_t position = firstFrame + frame;
        WERAISharedAudioFrame *slot = &buffer->frames[position % WERAI_SHARED_AUDIO_CAPACITY_FRAMES];
        __atomic_store_n(&slot->sequence, WERAI_SHARED_AUDIO_SEQUENCE_IN_PROGRESS, __ATOMIC_RELEASE);
        __atomic_store_n(&slot->samplePosition, position, __ATOMIC_RELAXED);
        __atomic_store_n(&slot->hostTime, firstHostTime + (uint64_t)((double)frame * hostTicksPerFrame), __ATOMIC_RELAXED);
        uint32_t leftBits;
        uint32_t rightBits;
        memcpy(&leftBits, &samples[frame * 2], sizeof(leftBits));
        memcpy(&rightBits, &samples[frame * 2 + 1], sizeof(rightBits));
        __atomic_store_n(&slot->sampleBits[0], leftBits, __ATOMIC_RELAXED);
        __atomic_store_n(&slot->sampleBits[1], rightBits, __ATOMIC_RELAXED);
        __atomic_store_n(&slot->sequence, position + 1, __ATOMIC_RELEASE);
    }
    __atomic_store_n(&buffer->latestFrameExclusive, firstFrame + frameCount, __ATOMIC_RELEASE);
}

bool WERAISharedAudioRead(const WERAISharedAudioBuffer *buffer, uint64_t samplePosition,
                          float samples[WERAI_SHARED_AUDIO_CHANNELS], uint64_t *hostTime) {
    if (buffer == NULL) return false;
    const WERAISharedAudioFrame *slot = &buffer->frames[samplePosition % WERAI_SHARED_AUDIO_CAPACITY_FRAMES];
    uint64_t firstSequence = __atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE);
    if (firstSequence != samplePosition + 1) return false;
    uint32_t leftBits = __atomic_load_n(&slot->sampleBits[0], __ATOMIC_RELAXED);
    uint32_t rightBits = __atomic_load_n(&slot->sampleBits[1], __ATOMIC_RELAXED);
    uint64_t timestamp = __atomic_load_n(&slot->hostTime, __ATOMIC_RELAXED);
    uint64_t secondSequence = __atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE);
    if (firstSequence != secondSequence ||
        __atomic_load_n(&slot->samplePosition, __ATOMIC_RELAXED) != samplePosition) return false;
    memcpy(&samples[0], &leftBits, sizeof(leftBits));
    memcpy(&samples[1], &rightBits, sizeof(rightBits));
    if (hostTime != NULL) *hostTime = timestamp;
    return true;
}

uint64_t WERAISharedAudioLatestFrame(const WERAISharedAudioBuffer *buffer) {
    return buffer == NULL ? 0 : __atomic_load_n(&buffer->latestFrameExclusive, __ATOMIC_ACQUIRE);
}

uint64_t WERAISharedAudioLatestReadableFrame(const WERAISharedAudioBuffer *buffer) {
    uint64_t latest = WERAISharedAudioLatestFrame(buffer);
    return latest > WERAI_SHARED_AUDIO_READER_SAFETY_FRAMES
        ? latest - WERAI_SHARED_AUDIO_READER_SAFETY_FRAMES : 0;
}

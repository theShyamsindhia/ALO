// Copyright (c) 2026 WERAI contributors. MIT licensed.
#ifndef WERAI_SHARED_AUDIO_H
#define WERAI_SHARED_AUDIO_H

#include <stdbool.h>
#include <stdint.h>

// POSIX shared-memory names on macOS allow one leading slash and no path separators.
#ifndef WERAI_SHARED_AUDIO_NAME
#define WERAI_SHARED_AUDIO_NAME "/alo-audio-frames-v2"
#endif
#define WERAI_SHARED_AUDIO_MAGIC UINT64_C(0x5745524149415544)
#define WERAI_SHARED_AUDIO_VERSION 2u
#define WERAI_SHARED_AUDIO_CHANNELS 2u
#define WERAI_SHARED_AUDIO_CAPACITY_FRAMES 32768u
#define WERAI_SHARED_AUDIO_READER_SAFETY_FRAMES 256u
#define WERAI_SHARED_AUDIO_SEQUENCE_IN_PROGRESS UINT64_MAX

// One producer (the HAL driver) and one consumer (WERAI) may map this structure.
// The producer first release-stores an in-progress marker, replaces the slot, then
// release-stores sequence = samplePosition + 1.
// The consumer acquire-loads sequence before and after copying and accepts a frame only
// when both values match the requested sample position. The plain integer layout imports
// cleanly through a Swift bridging target; use the accessor functions for atomic operations.
typedef struct {
    uint64_t sequence;
    uint64_t samplePosition;
    uint64_t hostTime;
    uint32_t sampleBits[WERAI_SHARED_AUDIO_CHANNELS];
} WERAISharedAudioFrame;

typedef struct {
    uint64_t magic;
    uint32_t version;
    uint32_t headerSize;
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t capacityFrames;
    uint32_t reserved;
    uint64_t generation;
    uint64_t latestFrameExclusive;
    WERAISharedAudioFrame frames[WERAI_SHARED_AUDIO_CAPACITY_FRAMES];
} WERAISharedAudioBuffer;

WERAISharedAudioBuffer *WERAISharedAudioCreateProducer(void);
WERAISharedAudioBuffer *WERAISharedAudioOpenConsumer(void);
void WERAISharedAudioClose(WERAISharedAudioBuffer *buffer);
void WERAISharedAudioBeginTimeline(WERAISharedAudioBuffer *buffer);
void WERAISharedAudioPublish(WERAISharedAudioBuffer *buffer, uint64_t firstFrame,
                             uint64_t firstHostTime, double hostTicksPerFrame,
                             const float *samples, uint32_t frameCount);
bool WERAISharedAudioRead(const WERAISharedAudioBuffer *buffer, uint64_t samplePosition,
                          float samples[WERAI_SHARED_AUDIO_CHANNELS], uint64_t *hostTime);
uint64_t WERAISharedAudioLatestFrame(const WERAISharedAudioBuffer *buffer);
uint64_t WERAISharedAudioLatestReadableFrame(const WERAISharedAudioBuffer *buffer);

#endif

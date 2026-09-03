#ifndef WERAI_SHARED_AUDIO_CLIENT_H
#define WERAI_SHARED_AUDIO_CLIENT_H
#include <stdint.h>
typedef void *WERAISharedAudioHandle;
// The producer is owned by _coreaudiod, so its POSIX shm object must be
// cross-user readable for this no-TCC transport. This client maps it read-only
// and validates owner, permissions, canonical size, and ABI; authenticated IPC
// is required to fully prevent another local account from reading the ring.
WERAISharedAudioHandle WERAISharedAudioClientOpen(void);
void WERAISharedAudioClientClose(WERAISharedAudioHandle handle);
uint64_t WERAISharedAudioClientGeneration(WERAISharedAudioHandle handle);
uint64_t WERAISharedAudioClientLatestFrame(WERAISharedAudioHandle handle);
int WERAISharedAudioClientRead(WERAISharedAudioHandle handle, uint64_t samplePosition,
                               float samples[2], uint64_t *hostTime);

// In-process SPSC ring used to move Core Audio tap samples off the synchronous
// IO callback without allocating, locking, or converting on that callback.
typedef void *ALOTapAudioRingHandle;
ALOTapAudioRingHandle ALOTapAudioRingCreate(void);
void ALOTapAudioRingDestroy(ALOTapAudioRingHandle handle);
uint64_t ALOTapAudioRingCapacity(void);
uint64_t ALOTapAudioRingLatestFrame(ALOTapAudioRingHandle handle);

/// Records that Core Audio entered the IO callback, even when the callback did
/// not contain renderable frames. This distinguishes a healthy silent tap from
/// a stopped audio device.
void ALOTapAudioRingMarkCallback(ALOTapAudioRingHandle handle);

/// Returns the number of Core Audio IO callbacks observed by this ring.
uint64_t ALOTapAudioRingLatestCallback(ALOTapAudioRingHandle handle);
void ALOTapAudioRingWriteInterleavedFloat(
    ALOTapAudioRingHandle handle,
    const float *samples,
    uint32_t frameCount,
    uint64_t firstHostTime,
    double hostTicksPerFrame
);
void ALOTapAudioRingWritePlanarFloat(
    ALOTapAudioRingHandle handle,
    const float *left,
    const float *right,
    uint32_t frameCount,
    uint64_t firstHostTime,
    double hostTicksPerFrame
);
uint32_t ALOTapAudioRingRead(
    ALOTapAudioRingHandle handle,
    uint64_t firstFrame,
    float *interleavedSamples,
    uint32_t maximumFrames,
    uint64_t *firstHostTime
);
#endif

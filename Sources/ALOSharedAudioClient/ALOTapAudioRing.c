#include "WERAISharedAudioClient.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

#define ALO_TAP_RING_CAPACITY 65536u
#define ALO_TAP_RING_IN_PROGRESS UINT64_MAX

_Static_assert(__atomic_always_lock_free(sizeof(float), 0),
               "The real-time tap requires lock-free 32-bit atomics");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0),
               "The real-time tap requires lock-free 64-bit atomics");

typedef struct {
    _Atomic uint64_t sequence;
    _Atomic float left;
    _Atomic float right;
    _Atomic uint64_t hostTime;
} ALOTapAudioFrame;

typedef struct {
    uint64_t writePosition;
    _Atomic uint64_t latestFrameExclusive;
    _Atomic uint64_t callbackCount;
    ALOTapAudioFrame frames[ALO_TAP_RING_CAPACITY];
} ALOTapAudioRing;

ALOTapAudioRingHandle ALOTapAudioRingCreate(void) {
    return calloc(1, sizeof(ALOTapAudioRing));
}

void ALOTapAudioRingDestroy(ALOTapAudioRingHandle handle) {
    free(handle);
}

uint64_t ALOTapAudioRingCapacity(void) {
    return ALO_TAP_RING_CAPACITY;
}

uint64_t ALOTapAudioRingLatestFrame(ALOTapAudioRingHandle handle) {
    if (handle == NULL) return 0;
    ALOTapAudioRing *ring = handle;
    return atomic_load_explicit(&ring->latestFrameExclusive, memory_order_acquire);
}

void ALOTapAudioRingMarkCallback(ALOTapAudioRingHandle handle) {
    if (handle == NULL) return;
    ALOTapAudioRing *ring = handle;
    atomic_fetch_add_explicit(&ring->callbackCount, 1, memory_order_release);
}

uint64_t ALOTapAudioRingLatestCallback(ALOTapAudioRingHandle handle) {
    if (handle == NULL) return 0;
    ALOTapAudioRing *ring = handle;
    return atomic_load_explicit(&ring->callbackCount, memory_order_acquire);
}

static void ALOTapAudioRingWriteFrame(
    ALOTapAudioRing *ring,
    uint64_t position,
    float left,
    float right,
    uint64_t hostTime
) {
    ALOTapAudioFrame *slot = &ring->frames[position % ALO_TAP_RING_CAPACITY];
    atomic_store_explicit(&slot->sequence, ALO_TAP_RING_IN_PROGRESS, memory_order_release);
    atomic_store_explicit(&slot->left, left, memory_order_relaxed);
    atomic_store_explicit(&slot->right, right, memory_order_relaxed);
    atomic_store_explicit(&slot->hostTime, hostTime, memory_order_relaxed);
    atomic_store_explicit(&slot->sequence, position + 1, memory_order_release);
}

void ALOTapAudioRingWriteInterleavedFloat(
    ALOTapAudioRingHandle handle,
    const float *samples,
    uint32_t frameCount,
    uint64_t firstHostTime,
    double hostTicksPerFrame
) {
    if (handle == NULL || samples == NULL || frameCount == 0) return;
    ALOTapAudioRing *ring = handle;
    uint64_t position = ring->writePosition;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        uint64_t hostTime = firstHostTime + (uint64_t)((double)frame * hostTicksPerFrame);
        ALOTapAudioRingWriteFrame(
            ring,
            position + frame,
            samples[frame * 2],
            samples[frame * 2 + 1],
            hostTime
        );
    }
    ring->writePosition = position + frameCount;
    atomic_store_explicit(
        &ring->latestFrameExclusive,
        ring->writePosition,
        memory_order_release
    );
}

void ALOTapAudioRingWritePlanarFloat(
    ALOTapAudioRingHandle handle,
    const float *left,
    const float *right,
    uint32_t frameCount,
    uint64_t firstHostTime,
    double hostTicksPerFrame
) {
    if (handle == NULL || left == NULL || right == NULL || frameCount == 0) return;
    ALOTapAudioRing *ring = handle;
    uint64_t position = ring->writePosition;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        uint64_t hostTime = firstHostTime + (uint64_t)((double)frame * hostTicksPerFrame);
        ALOTapAudioRingWriteFrame(
            ring,
            position + frame,
            left[frame],
            right[frame],
            hostTime
        );
    }
    ring->writePosition = position + frameCount;
    atomic_store_explicit(
        &ring->latestFrameExclusive,
        ring->writePosition,
        memory_order_release
    );
}

uint32_t ALOTapAudioRingRead(
    ALOTapAudioRingHandle handle,
    uint64_t firstFrame,
    float *interleavedSamples,
    uint32_t maximumFrames,
    uint64_t *firstHostTime
) {
    if (handle == NULL || interleavedSamples == NULL || maximumFrames == 0) return 0;
    ALOTapAudioRing *ring = handle;
    uint64_t latest = atomic_load_explicit(
        &ring->latestFrameExclusive,
        memory_order_acquire
    );
    if (firstFrame >= latest) return 0;
    uint64_t available = latest - firstFrame;
    uint32_t count = available < maximumFrames ? (uint32_t)available : maximumFrames;

    for (uint32_t frame = 0; frame < count; ++frame) {
        uint64_t position = firstFrame + frame;
        ALOTapAudioFrame *slot = &ring->frames[position % ALO_TAP_RING_CAPACITY];
        uint64_t firstSequence = atomic_load_explicit(&slot->sequence, memory_order_acquire);
        if (firstSequence == ALO_TAP_RING_IN_PROGRESS || firstSequence != position + 1) {
            return frame;
        }
        float left = atomic_load_explicit(&slot->left, memory_order_relaxed);
        float right = atomic_load_explicit(&slot->right, memory_order_relaxed);
        uint64_t hostTime = atomic_load_explicit(&slot->hostTime, memory_order_relaxed);
        uint64_t secondSequence = atomic_load_explicit(&slot->sequence, memory_order_acquire);
        if (firstSequence != secondSequence) return frame;
        if (frame == 0 && firstHostTime != NULL) *firstHostTime = hostTime;
        interleavedSamples[frame * 2] = left;
        interleavedSamples[frame * 2 + 1] = right;
    }
    return count;
}

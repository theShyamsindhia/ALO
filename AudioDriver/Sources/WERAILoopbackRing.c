// Copyright (c) 2026 WERAI contributors. MIT licensed.
#include "WERAILoopbackRing.h"
#include <string.h>

void WERAILoopbackRingClear(WERAILoopbackRing *ring) {
    memset(ring, 0, sizeof(*ring));
}

void WERAILoopbackRingWrite(WERAILoopbackRing *ring, uint64_t firstFrame, const float *samples, uint32_t frameCount) {
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const uint64_t timelineFrame = firstFrame + frame;
        const uint32_t slot = (uint32_t)(timelineFrame % WERAI_RING_CAPACITY_FRAMES);
        ring->samples[slot * 2] = samples[frame * 2];
        ring->samples[slot * 2 + 1] = samples[frame * 2 + 1];
        __atomic_store_n(&ring->frameTags[slot], timelineFrame + 1, __ATOMIC_RELEASE);
    }
}

void WERAILoopbackRingRead(const WERAILoopbackRing *ring, uint64_t firstFrame, float *samples, uint32_t frameCount) {
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const uint64_t timelineFrame = firstFrame + frame;
        const uint32_t slot = (uint32_t)(timelineFrame % WERAI_RING_CAPACITY_FRAMES);
        if (__atomic_load_n(&ring->frameTags[slot], __ATOMIC_ACQUIRE) == timelineFrame + 1) {
            samples[frame * 2] = ring->samples[slot * 2];
            samples[frame * 2 + 1] = ring->samples[slot * 2 + 1];
        } else {
            samples[frame * 2] = 0.0f;
            samples[frame * 2 + 1] = 0.0f;
        }
    }
}

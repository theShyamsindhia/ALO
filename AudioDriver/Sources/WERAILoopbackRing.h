// Copyright (c) 2026 WERAI contributors. MIT licensed.
#ifndef WERAI_LOOPBACK_RING_H
#define WERAI_LOOPBACK_RING_H

#include <stdint.h>

#define WERAI_RING_CHANNELS 2u
#define WERAI_RING_CAPACITY_FRAMES 32768u

typedef struct {
    float samples[WERAI_RING_CAPACITY_FRAMES * WERAI_RING_CHANNELS];
    uint64_t frameTags[WERAI_RING_CAPACITY_FRAMES];
} WERAILoopbackRing;

void WERAILoopbackRingClear(WERAILoopbackRing *ring);
void WERAILoopbackRingWrite(WERAILoopbackRing *ring, uint64_t firstFrame, const float *samples, uint32_t frameCount);
void WERAILoopbackRingRead(const WERAILoopbackRing *ring, uint64_t firstFrame, float *samples, uint32_t frameCount);

#endif

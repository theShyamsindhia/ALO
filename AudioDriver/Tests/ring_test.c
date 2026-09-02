#include "WERAILoopbackRing.h"
#include "WERAISharedAudio.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

_Static_assert(sizeof(WERAISharedAudioFrame) == 32, "shared frame ABI changed");
_Static_assert(__builtin_offsetof(WERAISharedAudioBuffer, frames) == 48, "shared header ABI changed");

int main(void) {
    shm_unlink(WERAI_SHARED_AUDIO_NAME);
    WERAILoopbackRing ring;
    WERAILoopbackRingClear(&ring);
    float source[8] = { 1, -1, 2, -2, 3, -3, 4, -4 };
    float result[8] = { 9, 9, 9, 9, 9, 9, 9, 9 };
    WERAILoopbackRingWrite(&ring, WERAI_RING_CAPACITY_FRAMES - 2, source, 4);
    WERAILoopbackRingRead(&ring, WERAI_RING_CAPACITY_FRAMES - 2, result, 4);
    for (int i = 0; i < 8; ++i) assert(result[i] == source[i]);
    WERAILoopbackRingRead(&ring, 100, result, 1);
    assert(result[0] == 0 && result[1] == 0);

    WERAISharedAudioBuffer *producer = WERAISharedAudioCreateProducer();
    if (producer == NULL) { perror("WERAISharedAudioCreateProducer"); return 1; }
    float sharedSource[600];
    for (int i = 0; i < 600; ++i) sharedSource[i] = (float)i / 600.0f;
    WERAISharedAudioPublish(producer, 42, 1000, 10.0, sharedSource, 300);
    WERAISharedAudioBuffer *consumer = WERAISharedAudioOpenConsumer();
    assert(consumer != NULL);
    uint64_t hostTime = 0;
    float frame[2];
    assert(WERAISharedAudioRead(consumer, 44, frame, &hostTime));
    assert(frame[0] == sharedSource[4] && frame[1] == sharedSource[5] && hostTime == 1020);
    assert(!WERAISharedAudioRead(consumer, 41, frame, &hostTime));
    assert(WERAISharedAudioLatestFrame(consumer) == 342);
    assert(WERAISharedAudioLatestReadableFrame(consumer) == 86);
    WERAISharedAudioClose(consumer);
    WERAISharedAudioClose(producer);
    shm_unlink(WERAI_SHARED_AUDIO_NAME);

    // A pre-created object with the wrong size must never be resized or trusted.
    int squatted = shm_open(WERAI_SHARED_AUDIO_NAME, O_CREAT | O_EXCL | O_RDWR, 0644);
    assert(squatted >= 0);
    assert(ftruncate(squatted, 1) == 0);
    close(squatted);
    assert(WERAISharedAudioOpenConsumer() == NULL);
    assert(WERAISharedAudioCreateProducer() == NULL);
    shm_unlink(WERAI_SHARED_AUDIO_NAME);
    puts("ring contract passed");
}

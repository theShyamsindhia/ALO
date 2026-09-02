#include "WERAISharedAudio.h"
#include "WERAISharedAudioClient.h"
#include <assert.h>
#include <stdio.h>
#include <sys/mman.h>

int main(void) {
    shm_unlink(WERAI_SHARED_AUDIO_NAME);
    WERAISharedAudioBuffer *producer = WERAISharedAudioCreateProducer();
    assert(producer != NULL);
    float source[600];
    for (int i = 0; i < 600; ++i) source[i] = (float)i / 1000.0f;
    WERAISharedAudioPublish(producer, 1000, 5000, 2.0, source, 300);

    WERAISharedAudioHandle client = WERAISharedAudioClientOpen();
    assert(client != NULL);
    assert(WERAISharedAudioClientGeneration(client) != 0);
    assert(WERAISharedAudioClientLatestFrame(client) == 1044);
    float frame[2];
    uint64_t hostTime = 0;
    assert(WERAISharedAudioClientRead(client, 1043, frame, &hostTime));
    assert(frame[0] == source[86] && frame[1] == source[87] && hostTime == 5086);
    WERAISharedAudioClientClose(client);
    WERAISharedAudioClose(producer);
    shm_unlink(WERAI_SHARED_AUDIO_NAME);
    puts("shared client ABI passed");
}

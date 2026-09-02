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
#endif

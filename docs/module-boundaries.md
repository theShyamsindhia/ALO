# Module boundaries and contributor rules

The executable and the iOS app are adapters, not separate implementations of
network identity, channel admission, durable state or clock estimation.

| Boundary | Standard API | Do not add |
| --- | --- | --- |
| User identity | `ALOIdentity.UserIdentityStore`, `DeviceIdentityBinding` | Private keys in network manifests, diagnostics or Bonjour |
| Network/channel authority | `ALORooms.NetworkRepository`, signed `NetworkManifest` | Trust from a display name, UUID, Wi-Fi presence or old invite key |
| App account lifecycle | `ALOAppModel.NetworkAccountModel` | Silent identity replacement or joining before onboarding |
| Reliable peer connections | `ALONetworking.RoomPeerConnecting.openPeerChannel` | App-created sockets, custom handshakes, per-feature admission exceptions |
| Media/voice datagrams | Session-bound authenticated subscriptions | Reusing credentials, sequences or tickets after reconnect/revocation |
| Durable chat/queue | `AutomergeRoomStateSync` + `SecureRoomEventPolicy` | Treating all signed bytes as permission to affect the queue or chat |
| Media clock | `ALOTiming.ClockSynchronizer` via media control | UI timers, Automerge timestamps, wall clock or host work latency as audio time |

`ALONetworking` requires the same `NetworkChannelAuthorization` on control,
media-control, voice-control, file and video roles. Verify the root-signed device
binding against the **full actual TLS public-key hash**. Current-generation app
paths never fall back to old room admission. Legacy host/receiver implementations
remain as isolated regression fixtures; the `host` and `join` CLI entry points
explicitly reject use. New features must not call those implementations.

Policy updates are serialized and durably checked for rollback/equivocation.
The immutable in-memory policy snapshot is a separate fast read: media packet
authorization must not wait for policy JSON writes, file locks or signature
verification. Observers execute outside policy locks. Native app adapters stop
their active session and clear rejoin intent if their account loses access.

## Durable provenance versus authorized effects

An event's installation signature binds its root-authorized device, network,
owner, generation, channel and event body. This lets a new device verify a
current member's history even if the author's device is offline. Signature
verification alone cannot establish that an unseen event predates revocation.

- `allowsDurableStorage` validates bounded cryptographic records for CRDT sync.
- `accepts` validates the **local authorized projection**. Current members are
  allowed; removed authors need an exact locally committed historical receipt.
- `RoomStateSnapshot.events`, `.chatEvents` and `.queue` contain only the
  projection. `.retainedEvents` is raw signed storage for archive/replication,
  not UI, queue actions or Lamport advancement.
- Retention, queue tombstones and order changes must use the projection too.
  An inert revoked record cannot evict or remove an authorized record.
- `rememberAccepted` runs only after the entire transaction commits, and only
  on projected events. Failed candidates and inert storage never create receipts.
- Receipts cover exact bytes and are saved in an installation-signed,
  network/channel-bound archive. A snapshot from one worker must not erase a
  newly committed replica receipt awaiting ingestion on another worker.

A fresh device may therefore omit unseen history from removed users while still
converging the raw document and receiving new authorized messages. Already
accepted local history remains. This is intentional: there is no trusted global
timestamp or owner-signed historical checkpoint in this offline design. Inert
records are bounded by the document/transport budgets, not a permanent archive.

## Audio timing invariants

Read [local-audio-sync.md](local-audio-sync.md) before changing capture, buffering,
clock sampling, route transitions or renderer ownership. Never block the audio
callback on network, file I/O, UI, allocation-heavy conversion or cross-peer work.
One slow listener must not hold another listener's send queue or reset the
room timeline. A new media anchor cannot make stale clock evidence fresh.

## Regression gates

Run the full optimized suite and the unchanged strict live timing gates in CI.
Focused protections include `NetworkSecureChannelTests` (actual loopback TLS),
`NetworkEventAuthorizationTests`, `DurableAuthorizationProjectionTests`,
`NetworkAuthorizationTests`, `ClockSimulationTests`, `ClockReacquisitionTests`,
`MediaHostSessionTests`, `MediaReceiverSessionTests`, and the repeated room
scenarios. Native Mac snapshots and an unsigned iOS build check both adapters.
Simulations and loopback tests do not establish acoustic two-Mac/Bluetooth sync;
record that hardware acceptance separately, with output routes and versions.

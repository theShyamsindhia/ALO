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
Policy-frame decoding/verification is ordered off the shared channel executor;
changed-policy persistence has a bounded queue and deadline. Echoed policies do
not wait on disk locks. TLS verification and pin-store access use a bounded
worker pool, not the shared media queue. Every asynchronous admission completion
must recheck its connection generation and current channel access before
publishing ACKs or credentials. Cancellation cannot admit a late result.

## Durable provenance versus authorized effects

An event's installation signature binds its root-authorized device, network,
owner, generation, channel and event body. This lets a new device verify a
current member's history even if the author's device is offline. Signature
verification alone cannot establish that an unseen event predates revocation.

- `allowsDurableStorage` validates bounded cryptographic records for CRDT sync.
- `accepts` validates the **local authorized projection**. Current members are
  allowed within their live negotiated capabilities; removed authors need an
  exact locally committed historical receipt. Without live admission, portable
  proofs authorize durable history only, never broadcaster/playback control.
- `RoomStateSnapshot.events`, `.chatEvents` and `.queue` contain only the
  projection. `.retainedEvents` is raw signed storage for archive/replication,
  not UI, queue actions or Lamport advancement.
- Retention, queue tombstones and order changes must use the projection too.
  An inert revoked record cannot evict or remove an authorized record.
- Authorized retention with a projector is per signing author (up to
  500 chats, 5,000 queue records and the latest order per author), still subject
  to the global 5 MiB document budget. It cannot erase another author's records.
  The visible UI remains capped at 500 chats. Otherwise two peers with different
  historical receipts can disagree about a legitimate retention deletion and
  permanently reject subsequent sync.
- Inert records have a separate limit of 1,024 events / 1 MiB encoded bytes.
  Exceeding it rejects the whole candidate without mutating committed history
  or receipts. A candidate adding inert bytes must also stay below the global
  proactive-fallback threshold. Do not evict those bytes from a shared CRDT just
  because one peer lacks receipts: another peer may legitimately retain them.
  The offending link may lose durable sync, but cannot poison the room's stored
  document or disable healthy peers. Self-certified unknown roots are not storage
  grants; their otherwise valid inert proofs consume only this bounded allowance.
- Cache projection checks only within a transaction, by exact encoded bytes.
  Swift `String` equality folds canonically equivalent Unicode and is not a
  signature/immutability boundary. Pure cryptographic proof verification has a
  separate 2,048-entry / 4 MiB exact-byte cache; authorization is never cached.
  Pin/check the authority revision across the transaction; discard a candidate
  if it changes. Production commit and receipt recording share a stable policy
  guard that never holds the fast media-authorization snapshot lock.
- `rememberAccepted` runs only after the entire transaction commits, and only
  on projected events. Failed candidates and inert storage never create receipts.
- Receipts cover exact bytes and are saved in an installation-signed,
  network/channel-bound archive. A snapshot from one worker must not erase a
  newly committed replica receipt awaiting ingestion on another worker.

A fresh device may therefore omit unseen history from removed users while still
converging the raw document and receiving new authorized messages. Already
accepted local history remains. This is intentional: there is no trusted global
timestamp or owner-signed historical checkpoint in this offline design. Inert
records are bounded separately from authorized state, not a permanent archive.

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

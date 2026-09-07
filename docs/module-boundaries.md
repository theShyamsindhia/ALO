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
- Queue tombstones, ordering and queue retention use the authorized projection.
  Inert records cannot remove another user's history or affect their queue.
- Retention scopes come from the verified **root user**, not freely generated
  installation IDs (up to 500 chats, 5,000 queue records and the latest order per
  root). Chat retention and validation count the same root's retained provenance,
  including inert records. Otherwise peers with partial historical receipts can
  disagree about legitimate deletions and permanently reject subsequent sync.
  This is a bounded cache, not an immutable moderation/audit archive: same-root
  chat eviction can retire older accepted entries even when newer entries are
  not displayed. It cannot authorize those newer entries or erase another root.
  The visible UI remains capped at 500 chats.
- All network retention additionally fits 8,192 records / 2 MiB of encoded data,
  below the 16,384-receipt and 5 MiB serialized-document limits. Budget checks run
  after legitimate same-root pruning; overflow rejects the candidate atomically
  instead of evicting another user's history. Both canonical and original stored
  JSON bytes count, so padding an equivalent encoding cannot bypass the budget.
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
- Retained records carry immutable canonical/source bytes and verified scope.
  Reuse them only on an exact source-byte match; do not re-encode every retained
  event for each edit, snapshot, or compaction. The 8,192-record regression checks
  encoding counts, not a machine-dependent microbenchmark threshold.
- `rememberAccepted` runs only after the entire transaction commits, and only
  on projected events. Failed candidates and inert storage never create receipts.
- Local network edits and relayed durable events commit on the bounded worker
  before replica/UI publication or gossip. Reserve local counters independently
  while commits are pending, and never reuse a rejected counter. Capacity errors
  report an unsent edit without disabling media or future durable work; only local
  failures carry `RoomStateOperationRejection` and may restore composer drafts.
  Generation/access fences reject late completions after leave or revocation.
- Split durable events from live control before cryptographic validation. Cold
  history-proof verification must run on the durable worker, not the executor
  shared with media. Recheck authorization when publishing the result; a proof
  cache hit never freezes membership or negotiated capability decisions.
- Suppress only exact-byte duplicates already known or pending, within the same
  bounded pending-work lifetime. Same-ID/different-byte events still require
  validation and cannot inherit a success. Publish committed history through the
  paced snapshot sender: a 500-event relay must not become 500 immediate TLS
  frames or 500 independent full-history transactions. Remote rejection is a
  diagnostic, not an assertion that the local composer's edit was unsent.
- Receipts cover exact bytes and are saved in an installation-signed,
  network/channel-bound archive. A snapshot from one worker must not erase a
  newly committed replica receipt awaiting ingestion on another worker.
- Recovery distinguishes the authoritative saved document from its optional
  events sidecar. Policy/retention rejection of the document fails closed without
  replacing it. If the document loaded successfully, a quota-rejected sidecar
  migration leaves that committed document usable. An authorization change still
  aborts recovery; without a valid document, rejected sidecar history must not
  silently become a successful empty restore.

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

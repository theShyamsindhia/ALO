# Network device messaging implementation checkpoint

This isolated transport/consent branch is not an enabled application feature.
No Codex command, local task discovery, app launch, or audio wire modification is
implemented. Tests were written before their corresponding implementation where
possible. The main-based focused eight-suite run now passes 45 tests; this is service-layer
validation, not an end-user feature or physical two-Mac delivery result.

## Implemented boundaries

- Separate TLS text listener/client with 24 KiB framed JSON, 16 admitted peers,
  bounded output queues and handshake/session deadlines. Local code explicitly
  starts it; there is no automatic discovery or audio-channel authorization.
- Purpose/network-generation/root/device bindings and fresh signed nonces checked
  against actual mutual-TLS SPKI identities, then current network membership.
- Local receiver grants choose task UUIDs; only opaque grant IDs go on the wire.
- 16 KiB UTF-8 text, burst five/ten per minute, 32 messages/256 KiB queue and bounded
  non-evicting dedupe records. Full journals reject new work rather than admit replays.
  Local retirement of revoked/expired grants reclaims capacity only after explicit
  acknowledgment of receipt-evidence loss; retired capabilities stay unauthorized.
  Identical authenticated duplicate receipts do not rewrite the durable journal.
- Owner-only, exclusive-writer journal using atomic rename and file/directory
  synchronization. Persist before receipt/admission. Restart disables all grants,
  cancels never-dispatched messages and preserves ambiguous dispatch as uncertain.
- Applied policy updates conservatively retire every connection/grant. Removing
  and re-adding membership cannot resurrect previously queued authority: sessions
  and grants synchronously check the published policy revision under its fence,
  independently of asynchronous observer delivery.
- Service APIs own their injectable receiver clock, sampling after serialization
  and again inside the stable-policy fence. Waiting callers cannot supply stale
  timestamps that bypass expiry or fault the service through call reordering.

## Review follow-up validation

- Bridge deadlines use `mach_continuous_time`, which includes system sleep;
  audio's `MonotonicClock` is untouched. Local expiry UI must use
  `DeviceMessagingClock`, not the audio clock.
- Receiver-only grant listing exposes IDs, private task mappings, expiry,
  revocation and record counts for explicit retirement after restart.
- A transient per-grant/root/full-SPKI query budget (burst five, refill ten/minute)
  charges all receipt queries before the shared-policy lock and digest/encoding.
  It survives reconnects, never allocates for arbitrary grant IDs and does not
  cause duplicate receipt fsyncs. Durable new-message limits remain separate.
- Disconnect/drop cancels pending challenges. Five-second preauthorization,
  eight pre-TLS slots separate from admitted connections, and four unknown-TLS
  slots reserve post-TLS room for known pins. Pins are not membership authority.
  These limits do NOT prevent denial of service: rotating certificates can occupy
  unknown slots, and eight pre-TLS sockets can exclude even known peers before
  identity is available. Network/interface access controls and actual deployment
  load testing remain necessary; established connections are not evicted.
- Exact framed-wire validation emits a local rejected event without disconnecting
  or inserting an awaiting receipt.
- Dropped owners cancel native resources and
  remove policy observers without requiring explicit `stop()`.

All six review resolutions above passed the seven-suite 39-test run in
`/tmp/alo-device-messaging.ktdBQI/review-fixes-green.log` (0.512 s runtime;
actual TLS consent/revocation/rejected-send recovery 0.130 s). Additional tests
cover permanent disablement after query-clock regression and stopped-listener
delayed callbacks. No application adapter or delivery claim is implied.

The first run passed 38/39 tests; only the port-rebind fixture failed
(`review-fixes-first.log`). Native diagnostics showed the original listener
reached cancelled, while the replacement failed POSIX EINVAL, not EADDRINUSE
(`listener-drop-diagnostic.log`). The isolated native control probe proved both
fresh and reused ports fail without an incoming-connection handler, while both
become ready with a handler (`listener-handler-results.log`). Adding that missing
handler corrected the fixture; no production cleanup behavior was changed to
make this test pass. All original deadlines and assertions remain, with no
disabled cases or timing relaxation. Previous failure logs are preserved.

CI at `6034f5e` subsequently exposed a distinct cancellation-ordering fixture
race: replacement failed EADDRINUSE while the original still reported ready;
the original reached cancelled later (`/tmp/alo-ci-6034f5e-failed.log`). Unlike
the earlier EINVAL, this proves the test attempted reuse before asynchronous
cancellation completed. The test now observes native cancelled before its single
rebind, within the same original three-second total budget (passed in the 45-test run).
There is no retry or deadline increase. Production `stop()`/owner destruction
requests cancellation; it does not promise synchronous port reuse. Future app
wiring that requires ordered same-port restart needs an explicit cancellation
completion contract. No such public completion API is claimed or added here.

## Second review follow-up validation

- Canonically sorted wire encoding feeds a 32-byte pending digest. Identical
  in-flight sends coalesce; different content with the same key rejects locally.
  Pending digests are bounded to 32 entries, not 32 retained payload frames.
- A receiver rate limit returns only a solicited `rateLimited` wire rejection.
  It consumes the sender's pending key, preserves the connection and never retries.
  Unknown rejection reasons or unsolicited keys still fail closed.
- Transport timers capture an absolute `ContinuousClock` deadline on the owner
  queue before starting a cancellable weak-owner task. Renewed generation checks
  occur back on that same queue. System-sleep inclusion is the Swift clock's
  documented contract, not a claim that tests suspended the real Mac.
- Faulted service mutations all reject; read-only grant inspection and connection
  cleanup remain available, but journal retirement requires a healthy service.
- Received grants are unique and capped at 32 before application callbacks.

New coverage includes a real TLS blocked-receiver duplicate/conflict test and
six-message rate-limit burst; pure production response-ledger rejection/grant
limits; arbitrary grant IDs allocating zero query buckets; and real continuous
timer expiry plus stale-generation rejection. Admission threshold helpers are
tested directly, not a claim of real socket-flood robustness. The 100-challenge
churn test exercises service cancellation directly; transport-close wiring is
currently verified by inspection, not a controlled 100-connection churn test.

All 45 tests in eight suites passed in 0.547 s, including actual TLS duplicate,
conflict and authoritative rate-limit behavior (0.127 s):
`/tmp/alo-device-messaging.ktdBQI/second-review-green.log`. A subsequent warning-only
fixture correction replaced async-context semaphore waiting with lock-backed
async polling, preserving the two-second entry and three-second release limits.
The affected two-test TLS suite passed separately in 0.230 s (actual TLS 0.169 s):
`/tmp/alo-device-messaging.ktdBQI/async-prerequisite-green.log`.

## Focused validation

- The branch is independently based on main `c07a605`; its diff contains only
  this transport/consent feature, tests and plans, not the separate audio/UI work.
- Main-based validation passed 29 tests in six suites in
  `/tmp/alo-device-messaging.ktdBQI/main-base-green.log` (0.363 s tests).
  An exact executor-helper probe first demonstrated overlapping work with the
  prior caller-queue assignment (`queue-red.log`); private serial target queues
  passed the same probe (`queue-green.log`) and a permanent ordering regression.
  Transport and listener both use that executor regardless of caller queue type.
- Initial compile-only failure (three missing throwing test reads) is preserved
  separately in `/tmp/alo-device-messaging.ktdBQI/revision-fence-red.log`; it is not
  a behavioral reproduction.
- Removing only the session/grant revision fences reproduced five expected issues
  in `/tmp/alo-device-messaging.ktdBQI/revision-fence-red-2.log`: old sessions and a
  fresh session using an old grant could admit independent queued messages after
  remove/re-add, before deferred policy observers ran. Other tests, including real
  TLS loopback, passed.
- Restored fences plus receiver-owned clock tests passed all 28 tests in six suites
  in `/tmp/alo-device-messaging.ktdBQI/revision-fence-green.log` (205.90 s build,
  0.300 s tests). Coverage includes expiry while waiting for either serialization
  fence, reordered callers, local retirement/restart, duplicate journal-write
  counts, framing limits, and actual TLS consent/revocation without an audio channel.

## Required before adapter shipment

`takeForDispatch` linearizes **durable admission only**, not external process start.
Returning its value and promising to execute it immediately is not an adequate
revocation fence. The adapter must serialize actual nonblocking handoff/start
against current policy and grant revocation, without waiting for CLI completion
under the policy persistence lock. A regression must pause after admission,
apply revocation, and prove stale work cannot start. This remains an explicit
blocking integration requirement; this branch performs no external side effect.

The follow-on adapter must provide owner-UID-validated local ingress, local task
registration and explicit approval/revoke controls, pinned supported Codex queue
invocation, and independent existing-desktop-task delivery confirmation. Queued
receipts are not delivered/read receipts. No private desktop IPC fallback.

Independent reviews, required CI, real two-Mac consent/revocation tests outside
audio channels and during playback, and per-installation Codex delivery capability
checks remain required. Anytype remains bootstrap until those checks pass.

All tests use local fixtures/ephemeral keys. Native TLS loopback is not a two-Mac
or existing-Codex-task integration result. Unknown offline revocations cannot be
enforced until the receiver learns them.

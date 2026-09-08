# Network device messaging implementation checkpoint

This isolated transport/consent branch is not an enabled application feature.
No Codex command, local task discovery, app launch, or audio wire modification is
implemented. Tests were written before their corresponding implementation where
possible. The main-based focused six-suite run now passes 29 tests; this is service-layer
validation, not an end-user feature or physical two-Mac delivery result.

## Implemented boundaries

- Separate TLS text listener/client with 24 KiB framed JSON, 16-connection cap,
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

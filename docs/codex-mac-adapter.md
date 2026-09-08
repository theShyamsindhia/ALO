# Internal Mac queue adapter

This stacked implementation is deliberately not wired to ALO or the transport
service. `takeForDispatch` is a durable reservation, not an actual native-spawn
revocation fence. Integration must revalidate consent and membership under shared
serialization immediately around native process start, then release locks before
waiting. Do not call the current synchronous runner while holding policy locks.

The internal adapter now exposes `Runner.prepare`, single-use `Prepared.start`,
and idempotent `Started.waitForOutcome`; `Runner.run` delegates to them for the
existing tests. Preparation validates/hashes/configures only, and abandoning it
closes pipes without launching. Start consumes its preparation even on launch
failure and performs no hashing or waiting. Waiting computes one cached outcome
outside policy locks. Dropping an owned started handle requests child termination
and closes pipes without waiting (not descendant-process containment). The new
split is not itself authorization: service-fence integration below remains design
only. Added marker-helper tests cover no-spawn preparation/abandonment, duplicate
start exclusion, repeated outcome reads and actual native launch failure.

Validation checkpoint: all 12 `MacCodexQueueAdapterTests` passed in 4.453 seconds
(optimized build 181.99 seconds, exit zero). The original nine-test baseline and
the polling-race RED are preserved separately. Final log:
`/tmp/alo-codex-mac-adapter.9xPTlE/adapter-split-green.log`.
Command: `swift test -c release --jobs 1 --no-parallel -Xswiftc -num-threads
-Xswiftc 1 -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CapturePropagation
-Xswiftc -Xllvm -Xswiftc -sil-disable-pass-only-function=main
--filter MacCodexQueueAdapterTests`, run at nice 19. This is focused adapter
validation with harmless helpers, not full-app, policy-fence, or actual Codex
delivery validation.

The internal builder accepts a UUID selected by local consent, authenticated root
identity, message UUID, and at most 16 KiB of peer text. It emits only the fixed
`queue --thread UUID --message TEXT` argument array. JSON attribution preserves
the peer text as data and explicitly denies additional user authority. It is not
a guarantee that a receiving language model will ignore prompt injection.

The receiver approves a canonical executable path and SHA-256 digest. No PATH
lookup, peer executable, task name, config flags, cwd, or environment is accepted.
The runner uses the local owner's home and a minimal environment. Rechecking the
digest catches replacement before launch; Foundation Process still executes by
pathname, so local replacement between verification and exec is a documented
TOCTOU limitation, not a peer-security or code-signing guarantee.

Normal exit zero means `codexQueued`, never delivered/read. A started process
with nonzero exit, signal, or timeout is uncertain and must not be automatically
retried. Pre-start validation/launch failure is definitely not queued. Receipt
confirmation remains a separate feature requiring actual selected-task evidence.

Each pipe retains at most 8 KiB while continuing bounded nonblocking drains.
Execution waiting uses a monotonic deadline (default five seconds, maximum 30),
then TERM with a 100 ms grace followed by KILL if still running. Native spawn
itself is synchronous; the deadline bounds child waiting, not arbitrary OS launch
or filesystem stalls. The runner does not wait for pipe EOF, which descendants
could retain. It does not claim process-tree containment: an approved executable
must itself be trusted not to detach work. Raw captures are internal diagnostics,
not logs, and may contain private task/message information.

Tests only create temporary harmless helper programs. They never invoke installed
Codex, enumerate tasks, inspect private IPC/databases, or send real messages.
Actual process-start fencing, owner-only ingress, opt-in UI, capability verification,
and two-device delivery remain out of scope for this internal adapter checkpoint.

Diagnostic validation found a genuine polling race: an actual child observed
exited with status zero after loop admission was still labeled timed out. The
deadline path now reobserves running state before cancellation. This is separate
from the initial 500 ms descendant-pipe fixture failure: counted native probes
showed fresh helper scripts still alive until roughly 515–609 ms, while later
launches exited in 8–18 ms. The initial short deadline did not establish that the
parent had exited. Sleep deltas were 7–9 ms, not the initially (and incorrectly)
inferred 500 ms; no timer-coalescing cause is claimed. Native Foundation exit
observation did not wait for descendant-held pipe EOF. The original failure logs
are preserved. The replacement fixture observes real parent exit status zero and
an actual nonblocking EAGAIN read (not EOF) before requiring bounded return; it
keeps the 500 ms runner timeout and bounds its own exit-observation prerequisite.

## Proposed next integration boundary (design only)

Inspected the bridge owner's frozen working tree on September 8, 2026. This is
not a copy of that WIP and does not change PR5. The relevant current structure is:

- `CodexDeviceMessageService.current(connection:queryGrant:_:)` acquires the
  service NSLock, then `NetworkDeviceAuthorization.withCurrentContext` acquires
  `NetworkPolicyCenter.withStablePolicy`'s updateLock and samples the receiver
  continuous clock. Exact policy revision, membership, generation, root and
  installation-SPKI scope are checked, not just an observer notification.
- Local revoke/disable uses the same service lock. Applied manifest changes use
  updateLock; observers run after updateLock is released and subsequently acquire
  the service lock. Preserve this ordering; do not add updateLock-to-service-lock
  calls while still holding updateLock.
- Current `takeForDispatch` commits `.dispatching`, erases retained text, then
  returns. It is only a reservation; do not use it as an adapter preflight API.
- Current completion only accepts `.dispatching`. Revoke changes this to
  `.uncertain`; restoration also converts dispatching to uncertain and never
  reenables grants. Completion after revocation must account for that transition.

### Proposed internal APIs and ordering

1. `service.prepareDispatch(envelopeID:connection:) -> PreparedDispatch` reads an
   already-received record under current authorization but leaves its durable
   receipt `.received`. Return a bounded, opaque, non-Codable candidate binding
   service instance, connection, grant/message IDs, stored digest, local task UUID,
   sender and original text. Construct it only inside the service. Preparing twice
   grants no duplicate authority: the eventual `.received` state transition is
   still single-use. Avoid a second unbounded preparation queue; reuse the existing
   maximum 32 received/in-flight records and a bounded local worker.
2. `adapter.prepare(candidate, approvedExecutable) -> PreparedNativeQueue` runs
   outside both locks. Validate text, build JSON/argv, verify the executable pin,
   allocate/configure Process and nonblocking pipes, and prepare fixed local
   environment/cwd. This step performs no native launch and no durable dispatch
   transition. The candidate's content is a snapshot, never cached authorization.
   Binary and text hashing, encoding and filesystem preflight stay out of the
   policy fence. The existing pathname TOCTOU limitation still applies.
3. `service.startPrepared(candidate, native) -> StartedDispatch` takes service
   lock then stable-policy updateLock, revalidates the connection and grant at a
   freshly sampled continuous time, and matches the candidate to the unchanged
   `.received` record and local destination. Comparing the already-stored digest
   does not rehash peer bytes. Only then persist `.dispatching` immediately before
   attempting spawn, within this same fence. Persistence failure means no spawn.
   Re-sample continuous time after the durable write and check grant/session
   expiry and clock regression again: fsync can consume the remaining lifetime.
   Policy revision cannot change while updateLock is held; do not recursively
   reenter `withCurrentContext` to perform this second time check.
4. Invoke only `PreparedNativeQueue.start()` inside that critical section: a
   concrete, trusted, synchronous native spawn operation, not an arbitrary
   application callback and not the current all-in-one `Runner.run`. Do not hash,
   encode, wait for exit, drain output, perform task discovery or invoke caller
   callbacks here. Return a single-use `StartedDispatch` containing the native
   handle and message/attempt ticket, then release both locks. App-level queues
   cannot interpose an asynchronous gap between final authorization and spawn.
5. `started.waitForOutcome()` performs all polling, drains and timeout handling
   outside locks. `service.finishStarted(ticket:result:)` later commits the
   bounded outcome exactly once under the service lock. CLI exit zero remains
   queued, never delivered. A record already made uncertain by revoke/policy
   invalidation must remain conservative; a late completion must not revive
   consent, requeue text, overwrite a deliberately retired record, or trigger a
   second launch. Explicitly represent "completion superseded" rather than
   treating that race as an instruction to retry.

The durable pre-spawn intent is necessary: persisting only after spawn could
replay an already-enqueued message after a crash. A crash in the tiny interval
between durable intent and launch is conservatively uncertain even if no child
actually started; this false uncertainty is preferable to duplicate delivery.
If launch is known to fail before any child starts, persist cancelled. If expiry
is detected after intent but before launch, also cancel without spawning. If any
terminal persistence fails, leave the service faulted and never retry automatically.

The fence linearizes against **locally applied** membership changes and local
revoke, not an unknown remote update. If revoke wins the lock first, no launch is
allowed; if native spawn wins first, revoke cannot undo content already queued.
It must still prevent every later start. A pending remote policy operation that
has not been published is not yet an applied revocation.

`Process.run()` is a synchronous OS launch call, not a mathematically bounded
wall-clock operation. Preparing everything outside the fence minimizes its scope
but does not prove a hard upper bound on OS scheduling/launch stalls. Measure the
critical section with harmless helpers; if a hard spawn bound is required, review
a lower-level spawn primitive separately. Do not claim that an asynchronous spawn
or a timeout wrapper preserves the same revocation fence.

### File ownership for the future implementation

- `CodexDeviceMessagingPolicy.swift`: internal candidate validation, single-use
  dispatch intent and post-persistence time check, conservative completion rules.
- `CodexDeviceMessageService.swift`: prepare/start/finish ordering and ticket
  ownership under its existing lock; no additional public peer protocol fields.
- `MacCodexQueueAdapter.swift`: split preparation, synchronous native start, and
  bounded waiting; no app entry point until the fence is tested and reviewed.
- New service/adapter integration tests: exact revocation races and crash cases.
  Existing transport, UI, local ingress and discovery remain unchanged.

### Required deterministic tests before wiring

- Pause after native preparation but before acquiring start authorization; apply
  local revoke, disable, expiry, or membership removal, then resume. Assert no
  child start and no helper marker. Delay policy observer delivery in the removal
  case: synchronous revision validation must still reject it.
- Race two prepared candidates for the same received record. Exactly one native
  start is permitted; duplicate/late completion cannot release another ticket.
- With a controlled native-start primitive, hold the fenced start and race revoke:
  establish which operation linearizes first. Once start returns, allow revoke to
  finish while the harmless child is still alive, proving child waiting is outside
  locks. Also verify policy snapshot/media readers remain usable.
- Block binary hashing/preparation outside the fence and demonstrate revoke and
  policy publication complete without waiting for that preflight.
- Advance the injected continuous clock during journal persistence beyond expiry;
  assert no launch despite the prior successful authorization. Test backwards
  clock observation and failed durable intent too.
- Simulate crash after intent/before launch and after launch/before completion:
  restoration stays uncertain/disabled with no automatic second helper launch.
  Known spawn failure is cancelled; terminal journal failure fails closed.
- Complete after revoke or explicit record retirement: do not revive authority,
  recreate deleted receipts, claim delivery, or retry uncertain work.

These tests should use barrier-controlled ordering, native helper markers and
bounded waits—not sleeps intended to make a race likely. No installed Codex,
private task IPC, real peer messages, or audio/hardware operations are needed.

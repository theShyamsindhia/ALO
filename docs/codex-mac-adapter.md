# Internal Mac queue adapter

This stacked implementation is deliberately not wired to ALO's app entry points.
The internal macOS service now provides candidate-bound native preparation,
start and ticketed completion. `takeForDispatch` remains a durable reservation,
not a native-spawn revocation fence; callers must use the new service path for
that guarantee. Never call the all-in-one synchronous runner under policy locks.

The internal adapter now exposes `Runner.prepare`, single-use `Prepared.start`,
and idempotent `Started.waitForOutcome`; `Runner.run` delegates to them for the
existing tests. Preparation validates/hashes/configures only, and abandoning it
closes pipes without launching. Start consumes its preparation even on launch
failure and performs no hashing or waiting. Waiting computes one cached outcome
outside policy locks. Dropping an owned started handle immediately sends SIGKILL
to its owned child (no grace period or child cleanup) and closes pipes without
waiting (not descendant-process containment). The new
split is not itself authorization: the concrete service fence below is required.
Added marker-helper tests cover no-spawn preparation/abandonment, duplicate
start exclusion, repeated outcome reads and actual native launch failure.

Validation checkpoint: all 12 `MacCodexQueueAdapterTests` passed in 4.453 seconds
(optimized build 181.99 seconds, exit zero). The original nine-test baseline and
the polling-race RED are preserved separately outside the repository.
Command: `swift test -c release --jobs 1 --no-parallel -Xswiftc -num-threads
-Xswiftc 1 -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CapturePropagation
-Xswiftc -Xllvm -Xswiftc -sil-disable-pass-only-function=main
--filter MacCodexQueueAdapterTests`, run at nice 19. This is focused adapter
validation with harmless helpers, not full-app, policy-fence, or actual Codex
delivery validation.

Both `.github/workflows/verify.yml` and `build-apple-silicon.yml` already compile
tests with the same test-only SIL entrypoint workarounds and execute them with
`--no-parallel`. These are not adapter-specific flags or production packaging
flags. Local `nice 19`, one build job and one frontend thread limit local load;
they are not a promise of idle CI hardware. The five-second default runner
deadline and two-second exit-observation prerequisite remain unchanged.

The internal builder accepts a UUID selected by local consent, authenticated root
identity, message UUID, and at most 16 KiB of peer text. It emits only the fixed
`queue --thread UUID --message TEXT` argument array. JSON attribution preserves
the peer text as data and explicitly denies additional user authority. It is not
a guarantee that a receiving language model will ignore prompt injection.

The receiver approves a canonical executable path and SHA-256 digest. No PATH
lookup, peer executable, task name, config flags, cwd, or environment is accepted.
`approvedDigest` exposes the locally computed digest; a subsequent explicit local
approval can supply `expectedDigest` and rejects any mismatch. No approval is
automatically saved, loaded or granted by this adapter.
Omitting `expectedDigest` is explicit new local approval/trust-on-first-use, not
restoration. Integration must persist the digest at genuine approval time and
pass it on every later construction; rebuilding approval from a path per dispatch
does not establish the previously approved binary's identity.
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
anchored at `Prepared.start()`, not the first `waitForOutcome()` call,
then TERM with a 100 ms grace followed by KILL if still running. Native spawn
itself is synchronous; the deadline bounds child waiting, not arbitrary OS launch
or filesystem stalls. The runner does not wait for pipe EOF, which descendants
could retain. It does not claim process-tree containment: an approved executable
must itself be trusted not to detach work. Raw captures are internal diagnostics,
not logs, and may contain private task/message information.
The fixed CLI contract also exposes attributed message text in process arguments
to same-user process inspection during the child's lifetime. Prefer a supported
stdin/file form if the CLI provides one in future; this adapter does not invent it.
Positive PID checks prevent accidentally signalling PID zero/process groups.
They do not eliminate Foundation's exit/reap/PID-reuse race between observation
and signalling; this remains a limitation of the current owned-Process approach.

Review follow-up tests strengthen environment isolation with a
set-and-restored canary, distinguish native launch failure from consumed-start
rejection, verify expected executable digests, and use a self-terminating
hold-file descendant instead of signalling a recorded raw PID. The original
timeout and pipe-open prerequisites are retained.
All 13 adapter tests passed in 2.745 seconds before rebasing onto PR5 `127e522`.
The subsequent `5e9372c` CI checkpoint passed 382 XCTest tests, 1,142 Swift tests
in 180 suites, seven repeatable tests in three suites, and both app builds
([run 34181281167](https://github.com/theShyamsindhia/ALO/actions/runs/34181281167)).
After rebasing onto PR5 `f178d6a`, a deterministic unchanged-drain regression
recorded three genuine failures: interrupted-read data loss, unreported work
budget exhaustion, and unreported I/O failure. EOF and would-block controls
passed. The bounded correction retries EINTR within the original 16-read limit
and conservatively marks incomplete capture on other errors or exhaustion.
All 14 adapter tests then passed in 2.761 seconds on this final base. Required CI
for the later correction is pending. No application or actual Codex delivery was
tested; these results are not an implemented service-to-spawn fence.

Tests only create temporary harmless helper programs. They never invoke installed
Codex, enumerate tasks, inspect private IPC/databases, or send real messages.
Owner-only app ingress, opt-in UI, actual Codex capability verification and
two-device delivery remain out of scope for this internal adapter checkpoint.

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

## Internal service integration boundary

The implemented API is `prepareNativeDispatch(grantID:messageID:connection:runner:)`,
`startPrepared(_:)`, and `finishStarted(_:)`. Preparation uses identifiers to read
the authenticated stored body/task/root; callers cannot supply replacement
content. An opaque native preparation retains this service-issued candidate and
cannot be paired with a different candidate by the caller. The snapshot also
retains its exact service issuer, network generation/revision and stored digest.

The service counts at most 32 permits across filesystem preflight, prepared and
started handles, releasing on abandonment/error/completion using a separate lock.
Dropping a started handle leaves durable dispatching evidence, restored as
uncertain, rather than received/retriable state. Deinit does not call back into
the service to publish uncertainty; explicit finish performs immediate receipt
publication. Native resource destruction retains the documented owned-child
kill behavior, not descendant containment.

Start commits intent and rechecks time against the SAME held policy context after
the actual journal save. It then invokes only concrete `Prepared.start` inside
the fence. Finish waits outside locks and rechecks record attempt identity and
synchronous policy revision; an observer delayed past removal/re-add cannot
cause a late result to revive authority. Expiry after durable intent cancels
without spawning; clock regression/persistence failure faults closed. No retry
or task-delivery claim follows uncertainty.

The preserved raw reservation baseline genuinely started a harmless helper after
revocation and failed the desired no-marker invariant. That documents the old
API limitation; the raw path remains a positive limitation control, not a claimed
behavioral repair. The initial integrated focused run passed 59 tests in six
suites. The strengthened exact task/root argv and observed-wait-entry run also
passed 59 tests in six suites (4.185 seconds); independent correction review
found no actionable gap. Required final-head integration CI remains separate.
The earlier `b3ecf9a` CI passed adapter tests but failed the room-scale fanout
minimum (45 versus 50); this focused pass does not resolve or conceal that failure.

Exact fence checkpoint `9a891be` later passed 382 XCTest tests, 1,160 Swift tests
in 182 suites, seven repeatable scenarios in three suites and both app builds
([run 34188316212](https://github.com/theShyamsindhia/ALO/actions/runs/34188316212)).
Its external review found two concrete behavioral issues: NUL could be admitted
despite native invocation rejection, and legacy caller-supplied completion could
overwrite a native-attempt receipt. The follow-up baseline recorded six issues
in eleven tests; strengthened retained-abandonment and actual-wait service/policy
access controls already passed. Admission now rejects NUL and legacy completion
requires a nil native attempt. Production finish has no callback parameter; its
separate test observer runs only outside service/policy locks. Follow-up validation
passed 63 tests in seven suites, including actual TLS cases (4.241 seconds total).
Required final-head CI and external follow-up review remain pending; the earlier
CI is not evidence for these later changes.

The following design checklist records the intended ordering and remaining
review/test opportunities; it does not claim every proposed adversarial case
below has been exercised.

Inspected the bridge owner's frozen working tree on September 8, 2026. This is
not a copy of that WIP and does not change PR5. The relevant current structure is:

- `CodexDeviceMessageService.current(_:queryGrant:_:)` acquires the
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

1. `service.prepareNativeDispatch(grantID:messageID:connection:runner:)` reads an
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
3. `service.startPrepared(native) -> StartedDispatch` takes service
   lock then stable-policy updateLock, revalidates the connection and grant at a
   freshly sampled continuous time, and matches the candidate to the unchanged
   `.received` record and local destination. The opaque native wrapper retains
   the service-minted candidate and derives its arguments solely from it; there
   is no caller-supplied candidate A beside a native preparation for B. Comparing the already-stored digest
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
   outside locks, beginning immediately after the fence releases rather than
   being queued behind other work; the child budget already runs from start.
   `service.finishStarted(ticket:result:)` later commits the
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

### Implementation files

- `CodexDeviceMessagingPolicy.swift`: internal candidate validation, single-use
  dispatch intent and post-persistence time check, conservative completion rules.
- `CodexDeviceMessageService.swift`: prepare/start/finish ordering and ticket
  ownership under its existing lock; no additional public peer protocol fields.
- `MacCodexQueueAdapter.swift`: split preparation, synchronous native start, and
  bounded waiting; restore only an actual approval-time digest. No app entry point
  until the fence is tested and reviewed.
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

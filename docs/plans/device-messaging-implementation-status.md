# Network device messaging implementation checkpoint

This draft transport/consent layer is not an enabled app feature. It implements
no Codex invocation, task discovery, app launch or audio wire changes.

## Boundaries and limits

- Explicit separate TLS listener/client. Fresh signed challenges bind purpose,
  network generation, roots and actual mutual-TLS SPKI identities. Sessions and
  grants synchronously verify current revision/membership independently of observers.
- Receiver-local opaque grants select private task UUIDs. Local listing permits
  deliberate retirement after restart, with acknowledgment of lost receipts.
- Global limits remain 32 queued messages/256 KiB, 1,024 receipts and 32 grants.
  Each grant has eight queued messages/64 KiB and 256 receipts. One grant cannot
  consume every global slot; this is not fairness for all 32 grants.
- Text:16 KiB UTF-8; framed payload:24 KiB. Stable per-grant/root/full-SPKI query
  budgets survive reconnects (burst five, refill ten/minute). Arbitrary IDs allocate
  no buckets. Identical duplicates do not rewrite the journal. Canonical pending
  digests coalesce identical sends and reject conflicts. Only solicited rate/capacity
  rejection keys resolve; no automatic retries. Grant callbacks are unique/bounded.
- Sleep-inclusive receiver clock and captured absolute continuous timer deadlines;
  weak-owner callbacks check generation on the private serial owner queue.
- Private exclusive-writer journal, atomic rename and file/directory fsync.
  **Process-crash recovery only: no power-loss/panic durability or rollback-proof
  receipt guarantee.** No F_FULLFSYNC guarantee. Restore disables grants, cancels
  received work and marks dispatching uncertain. Live text remains available for
  dispatch but is omitted from durable encoding. Cleanup after acquiring the writer
  lock removes only owned regular canonical receipt-UUID.tmp files, preserving
  unrelated files, directories and symlinks.
- Test clock/policy-delivery seams and journal load/save are internal. Listener
  construction validates its local TLS binding. Verification defaults to a separate
  concurrent queue; owner-queue processing/fsync stalls remain possible.
- Dropped owners request native cancellation and remove observers. Closed events
  are terminal, including same-frame post-send events and coalesced batches.
  Cancellation is asynchronous; ordered same-port app restart needs a completion
  contract, not an assumption that stop synchronously releases the port.

## Availability and evidence limitations

Five-second preauthorization, eight pre-TLS slots separate from admitted peers
and four unknown-TLS slots preserve some capacity for known pins. Pins are not
membership authority. Rotating certificates and pre-TLS socket occupation can
still exclude legitimate peers. No DoS-immunity claim is made. Threshold tests
exercise production helpers, not socket flooding. Challenge churn exercises
service cancellation, not 100 actual connection closures. Sleep inclusion follows
the Swift/Darwin clock contract; tests do not suspend the Mac.

## Validation

At 127e522, 45 tests in eight focused suites passed; the affected two-test TLS
suite passed again after a warning-only async prerequisite correction. CI passed
[run 34180976742](https://github.com/theShyamsindhia/ALO/actions/runs/34180976742):
382 XCTest, 1,129 Swift tests/179 suites and seven repeatable scenarios/three suites.
These results apply to that commit, not subsequent review fixes.

Baseline tests demonstrated revision-fence failures and concurrent caller-queue
overlap before fixes. Native fresh/reused-port controls proved an initial EINVAL
fixture failure was a missing accept handler. Later CI exposed EADDRINUSE while
the old listener was still ready; requiring native cancelled before one rebind
fixed the ordering within the same original three-second total deadline.

The latest review baseline produced ten genuine issues in twelve tests: encoded
and raw journal plaintext, per-grant receipt/count/byte limits, orphan cleanup,
local TLS mismatch, capacity response and post-close callbacks. Positive controls
retained exact live dispatch text and other-grant admission. After the fixes, all
51 tests in nine suites passed, including both native TLS cases. A subsequent
Sendable-clock warning cleanup passed 13 tests in three suites. Two final
unused-result warning-only test edits followed that run; they do not change test
conditions or production behavior and have not yet been recompiled.
Local forensic logs remain outside the repository, not inaccessible review citations.

Reproduce the hardware-free focused checks with the same test-only workarounds
as CI; production packaging flags are unchanged:

```sh
swift test -c release --jobs 1 --no-parallel \
  -Xswiftc -num-threads -Xswiftc 1 \
  -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CapturePropagation \
  -Xswiftc -Xllvm -Xswiftc -sil-disable-pass-only-function=main \
  --filter 'NetworkDeviceAuthorizationTests|CodexDeviceMessagingPolicyTests|CodexDeviceMessageServiceTests|NetworkDeviceMessageFrameTests|NetworkDeviceTextTransportTests|CodexDeviceMessageJournalTests|DeviceMessagingReviewTests|NetworkDeviceResponseLedgerTests|DeviceMessagingStorageReviewTests'
```

## Before app integration

takeForDispatch is durable reservation only, not external process-start authority.
Revalidate and fence actual nonblocking native start against revocation; wait for
completion outside locks. The native preparation must be opaque-bound to its exact
service-issued candidate/task/message, rejecting candidate swaps. Test revocation
between preparation/start and expiry during persistence before wiring.

Owner-UID ingress, task registration/approval UI, supported Codex invocation,
independent delivery confirmation, follow-up reviews and real two-Mac tests remain
required. Queued is not delivered/read. No private desktop IPC. Native TLS loopback
is not two-Mac delivery. Unknown offline revocations cannot be enforced until learned.

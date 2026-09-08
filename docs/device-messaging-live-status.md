# Live receipts and receiver-local facade

This stacked change adds a public macOS receiver facade and staged receipt
observations to the reviewed transport and native-start fence. It does not yet
wire the app's local executable approval UI, owner-UID task registration, peer
discovery, or the two-Mac consent workflow. No real Codex task has been queued by
these tests. The feature remains default disabled.

## Ownership and authority

`MacDeviceMessageReceiver` exclusively owns its supplied service's enable/stop
lifecycle and a listener. Do not share that service with a second controller.
Starting the listener does not enable the service. Explicit local consent calls
`setEnabled(true)` and approves a receiver-chosen local task on an opaque
`Connection`. The facade alone translates that handle to the authenticated
service session; a peer never selects the task or executable.

`CodexLocalExecutableApproval` hashes a receiver-approved local executable.
Supplying no expected digest means an explicit new local approval, not permission
to restore or approve a changed executable automatically. The app must retain
the approval-time digest if it persists approval. The underlying adapter still
uses fixed attributed arguments, and the service owns the actual native-start
revocation fence. The facade never accepts an Invocation or a caller result.

At most 32 operations, including pending owner-queue work, prepared handles, and
started handles, hold admission permits; at most four workers run concurrently.
The per-record admission key prevents duplicate queued workers. `dispatchStored`
returns a typed scheduled/alreadyScheduled/capacity/stopped/invalidConnection
outcome; scheduled is queue admission, not proof of native execution. Capacity
on an automatically accepted message and loss of its connection before admission
produce a connection-independent local `reviewNeeded` signal with stored receipt
evidence. Failed admission does not invent a receipt or retry: a still-received
record requires an explicit local attempt or retirement. A generic `dispatchFailed`
event is not evidence of non-execution: a post-start journal error can be
uncertain. Native-start failure and completion are recorded only by the service.
The ID-only `localReceipt` method reads immutable stored evidence under the service
lock even after local disable/revocation. It does not expose mutable policy or
authorize peer work. A missing record returns nil rather than claiming cancelled.

Enable and terminal stop share a lifecycle lock; a previously checked enable
cannot resume after stop and reactivate the service. Stop cancels pending workers
and disables service authority. Started helpers are bounded by the existing
adapter timeout. Waiting remains outside service/policy locks. A disconnected
connection gets no subsequent facade completion/failure event. Stored outcomes
remain available to a new authorized session without replaying text.

## Receipt protocol

The sender's `ready` event means authenticated transport readiness, not task
permission. Explicit receiver grant frames remain required for a new task grant.
On a fresh authenticated connection, a still-valid existing grant can be reused;
fresh nonces do not alter its root/full-SPKI/network-revision binding.

An initial `received` or `dispatching` receipt retains a bounded observation.
An identical intermediate update is coalesced; regression and unsolicited keys
fail closed. `codexQueued`, `uncertain`, `cancelled`, or independently evidenced
`delivered` ends that observation unless an explicit query is still in flight;
then only that bounded solicited response remains outstanding. **Queued is not delivered.** The total remains
32 observations, retaining only a digest and receipt stage, not another payload.

`queryReceipt(grantID:messageID:)` is an explicit status-only request on a settled
intermediate observation or after reconnect. Duplicate in-flight queries coalesce.
It never resends text, dispatches work, or automatically retries. Its authoritative
lookup is current-membership/grant fenced and shares
the stable per-grant replay budget across reconnects. Guessing unrelated grant
IDs cannot allocate new budgets. Receiver-local completion publication accepts
only IDs and re-reads each subscribed connection's authorized stored receipt.
It does not charge another remote query token. Receiver observations are also
bounded to 32 per connection and removed at terminal receipt or disconnect.
Query responses have a distinct wire kind from live updates. A live terminal
receipt arriving while a query is outstanding cannot cause the later solicited
response to look unsolicited. Query rate-limit/unavailable events clear only
query state and preserve any original message evidence; they are not text
rejection events. A current own-grant lookup with no record returns explicit
`statusUnknown`, never cancelled or definitely-not-queued. An expired grant ends
only that key's observation; foreign grants, expired sessions and current-policy
authorization failures remain connection-terminal. Existing accepted history is
not overwritten by an incompatible unknown response.
A raw 33rd observation is a protocol violation and closes the connection once,
without admitting work or generating repeated unbudgeted capacity replies. The
legitimate sender's same 32-entry bound prevents that frame locally. Ordinary
authorized service quota/rate rejections retain their solicited wire response.

Live updates are best effort while connected. Lost terminal receipts require a
new explicit status query. No acknowledgement or local event is promoted to
execution authority, and no automatic text resend is used to recover status.

## Validation checkpoint

Before the staged-ledger change, the single `NetworkDeviceLiveReceiptTests`
baseline compiled and failed with two runtime assertions: initial received
removed the only observation, and the later queued receipt was unauthorized.
The preserved baseline is a behavioral RED, not a missing-API compile failure.

The first focused run passed **23 tests in five suites**, including ledger
bounds/transitions, persistent query budgets, concurrent lifecycle stop, and
actual local TLS plus a bounded harmless helper (ordinary completion and
disconnect/reconnect status). Build time was 196.58 seconds; runtime was 2.583
seconds.

A subsequent raw-overflow regression accepted 32 real TLS messages, then tested
a raw 33rd text and status-query frame. Both variants failed precisely the
closed-at-handler-return assertion: **one test, two runtime issues** (193.52
seconds build, 1.061 seconds runtime). No setup, extra record, checkpoint, write,
or query-bucket assertion failed. This independently reproduces the unbudgeted
capacity-response path; a peer's later reaction cannot satisfy the immediate
receiver-side observation.

After the minimal strict-close correction, the same focused suites passed
**24 tests in five suites** (99.38 seconds build, 3.636 seconds runtime). Both
raw-overflow variants passed, as did the ordinary/reconnect facade, existing
native-start fence, ledger, and TLS consent controls. No deadline or assertion
was relaxed. No full-suite, app wiring, or physical two-Mac delivery claim follows
from these checkpoints.

Independent CodeRabbit review was clean. Claude identified six accepted bounded
status/API/test issues plus an unproven helper-timeout concern. The subsequent
production-unchanged baseline failed exactly **three runtime assertions across
five tests/two suites** (39.26 seconds build, 0.495 seconds runtime): suppressed
settled query, unknown own-grant status closing, and grant-only expiry closing
other valid work. Foreign-grant/session-expiry closure, unchanged journal, and
fresh-session revoked-grant controls passed. After the accepted corrections,
the focused matrix passed **28 tests in six suites** (202.51 seconds build,
4.120 seconds runtime). This includes explicit unknown/query-rate responses,
grant-scoped subscription expiry with healthy second-grant continuation,
disconnected local review, retained query evidence, and existing native-start
fence and raw-cap controls. No assertion or deadline was relaxed. This local
checkpoint does not establish full-suite, app integration, or two-Mac delivery.
The five-second native helper default is unchanged: prior local and full CI
passed, and no reproduced timeout failure justifies widening that gate.

Focused command (single native compiler lease):

```sh
nice -n 19 swift test -c release --jobs 1 --no-parallel \
  -Xswiftc -num-threads -Xswiftc 1 \
  -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CapturePropagation \
  -Xswiftc -Xllvm -Xswiftc -sil-disable-pass-only-function=main \
  --filter 'DeviceLiveStatusReviewTests|NetworkDeviceLiveReceiptTests|MacDeviceMessageReceiverTests|NetworkDeviceResponseLedgerTests|NetworkDeviceTextTransportTests|DeviceMessageSpawnFenceTests'
```

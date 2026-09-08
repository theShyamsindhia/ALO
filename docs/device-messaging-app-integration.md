# Device messaging app integration checkpoint

This is unshipped, opt-in macOS app wiring on the reviewed transport, native
spawn-fence, staged-receipt and owner-local ingress stack. It does not change
audio channel authority, start an installed app, discover private Codex IPC,
or approve a task based on a CLI exit code.

The separate pure controller checkpoint passed 25 tests in four suites after a
first compile-only Swift Testing macro error was corrected by evaluating
mutating expressions before assertions. The first runnable integration compiled
successfully but had three fixture readiness failures among 59 tests: macOS
canonicalized the approved helper path from `/private/tmp` to `/tmp`. A labeled
diagnostic run established that exact mismatch; correcting the expected
canonical path preserved the protected socket path and all timing limits.

The corrected owner controls then exposed one real failure among six tests:
explicit enable could not recover after an actual occupying socket owner
stopped. Generation-checked ingress-only failure cleanup fixed it. The full
focused checkpoint passed **60 tests in ten suites** (160.33-second build,
11.065-second runtime), including actual owner/socket/TLS/capability and existing
spawn/receipt regressions. Installed-app, two-owner outbound and physical
two-Mac delivery validation are not claimed by that result.

A subsequent actual two-owner test initially searched for the wrong public
status name (`received` instead of the existing `authenticatedReceipt`). The
source mapping established a test-oracle error, not dropped receipt evidence;
all task/body attribution, final queued and reconnect/no-resend assertions had
already passed. Using the actual status enum names preserved those assertions.
The resulting checkpoint passed **61 tests in ten suites** (84.32-second build,
11.077-second runtime). Two real local owners exercised socket registration,
harmless capability helpers/manual nonce confirmation, TLS/grant consent,
opaque destination binding, live intermediate→queued status without a query,
exact receiver task/sender root/message/body argv, duplicate no-extra-execution,
and explicit close→fresh authenticated status query with no text resend.
This remains local ephemeral validation, not installed-app or real-task proof.

## Explicit workflow

1. Open Settings → Device messaging; approve a local executable and explicitly
   enable owner-local ingress. No setting is enabled automatically on startup.
2. Copy the exact current app executable command from Settings to register the
   owning task. There is no assumed `alo` PATH symlink. Dev and release bundle
   identities resolve different short protected owner socket directories.
   Missing bundle identity fails closed rather than guessing release ALO.
3. Queue the fixed local capability test and enter the code observed in that
   actual task. The generated code is not shown as a shortcut in Settings.
   Queue exit is only queue evidence; manual confirmation is a same-UID local
   trust action, not process/task attestation.
4. Enable a saved network. Dedicated Bonjour candidates carry untrusted hints
   only; TLS/SPKI-bound purpose/network proof creates the actual consent row.
5. Receiver selects a verified local registration and explicitly approves the
   authenticated device. The durable local approval result supplies the real
   grant ID, even if its wire notification later fails. Sender binds a local
   registration to that actual receiver-issued destination.
6. Copy a bounded `send` command using stdin and a new message UUID. Initial
   receipt settles local work; live observations advance its recorded state.
   `codexQueued` is not `delivered`. Explicit status queries never resend text.

Disable/identity replacement invalidates local tickets and tears down actual
services/probes before reporting completed teardown. Receiver grants are
revoked, not silently deleted. Explicit acknowledgement in Settings can retire
revoked grants and their stored receipt history. Process-crash recovery is
supported by the journal; power-loss/panic rollback-proof receipts are not
promised. Text is not retained in durable checkpoints or diagnostic logs.

Known logical destinations may attach to an explicitly requested fresh TLS
connection only for the same root, full SPKI, network generation and policy
revision. That association sends no text/query. New status lookup is explicit;
unknown local message IDs never probe arbitrary peers. Membership revisions
retire the captured discovery/receiver instance and require explicit re-enable.

## New integration regression boundaries

### Corrective review checkpoint

The follow-up passed 63 optimized tests in 11 suites (13.675 seconds), including
real owner sockets, TLS, fixed harmless helper execution and receipt lookup.
This does not establish receipt in an actual Codex task or two-Mac acceptance.

- Held approvals settle when their network is retired, after synchronous grant
  revocation. A missing revocation context cannot acknowledge successful removal.
- Re-registering reports the existing registration state. Re-testing removes
  old local destinations; disconnect releases live observation bookkeeping.
- Settings can explicitly clear a settled local status to reclaim the 32-entry
  presentation capacity without removing receiver receipts or sending anything.
  Pending operations cannot be cleared. The rapid capacity test respects receiver
  rate limiting: rejected attempts also retain local status. Clearing local status
  does not grant additional receiver capacity or bypass duplicate protection.
- Ordinary incoming status notices cannot overwrite authority failure warnings.
- The bundled CLI and app derive the same short endpoint beneath Darwin's
  protected per-user temporary directory, with canonical ownership/mode checks;
  they do not trust an inherited TMPDIR or guess a release bundle identity.
- CLI responses are JSON. Refusals (`disabled`, `revoked`, `rejected`,
  `unavailable`, `definitelyNotQueued`) print that response and exit 1; other
  defined status responses exit 0. The switch is exhaustive for new statuses.
  Neither exit 0 nor `codexQueued` proves task delivery. Never blindly retry text.
- Enabling a network explicitly advertises device/network discovery metadata,
  including for networks owned by someone else. Authentication and receiver-local
  task consent remain necessary. This disclosure is stated in the enable UI.

Actual before-fix assertions reproduced retired-approval cleanup, repeated-register
status, conflicting message IDs, disconnect observation retention and stale
re-test destinations. The added rapid-capacity fixture initially expected all
messages to queue, contradicting the existing rate limit; its expectation was
corrected without changing any production rate or capacity threshold.

Final external corrective review and combined CI remain separate release gates.

The subsequent review-edge checkpoint passed 64 tests in 11 suites (13.616
seconds). It adds constant-length endpoint naming even for the largest UID,
exhaustive CLI status classification, revoked status while forgetting, ordinary
action notices that preserve authority errors, and per-network destination
retirement that also frees the reducer's destination budget. Actual policy
revision and re-test branches both clear stale Settings commands. Historical
statuses are explicitly described as no longer queryable after route retirement;
they do not authorize replay or replace the receiver's durable evidence.

- Actual held receiver construction then disable cannot enable/publish late.
- Actual hashed executable approval cannot cross identity/choice generation.
- Actual local socket registration, harmless capability helper output/manual
  confirmation, and real TLS grant approval exercise forget during delayed
  approval. Injected revocation failure keeps the actual grant tracked across
  repeated forget until revocation succeeds.
- Published membership revision replaces the captured discovery network set.
- Capability nonce history expires without a permanent 32-test lifetime cap;
  duplicates remain protected until expiry, and stopped probes reject work.
- Exact shell quoting, Dev/release endpoint mapping and bounded CLI rejection.

These boundaries and the two-owner outbound flow passed in the 63-test
checkpoint, including PR8's corrected competing socket-lock creation path.
Independent reviews, full CI and explicitly authorized physical app/real-task
testing remain required.

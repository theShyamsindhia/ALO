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

These boundaries passed in the 60-test checkpoint, including PR8's corrected
competing socket-lock creation path. Two-owner outbound validation, independent
reviews, full CI and explicitly authorized physical app testing remain required.

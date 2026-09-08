# Opt-in Codex device messaging

## Requested outcome

Allow an explicitly approved Codex task on one device to exchange live text
messages with an explicitly approved task on another ALO device. Replace the
Anytype coordination channel only after a real two-device delivery test passes.
This is separate from audio-channel membership and must not disturb playback.

## Delivery feasibility checkpoint

The installed Codex CLI exposes `queue --thread UUID --message TEXT`. A single
self-test was accepted for this desktop task and subsequently arrived in this
exact desktop conversation after its active turn ended. This proves queued
delivery at a turn boundary, not immediate active-turn steering. Acceptance
alone remains insufficient to claim delivery for other messages. The supported `app-server
proxy` default control socket is absent on this installation. Do not discover
private IPC, start another daemon, or resume a task in another server and claim
that it reaches the existing desktop conversation.

Before enabling each installation, verify queue delivery to the selected desktop
task. Immediate active-turn steering would require a supported, explicitly
configured app-server endpoint and separate verification.
The remote party may never change model, sandbox, tools, permissions, or executable
paths. Remote collaboration text is attributed peer content, not user authority.

## PR graph

1. **Network device messaging and consent** — independent feature branch targeting
   this repository's existing `main` workflow, separate from sync PR #4. High
   complexity. Add channel-independent authorization, bounded authenticated text
   transport, explicit per-device/task grants, revocation, replay protection and
   receipts. No audio-wire changes, attachments, shell execution or Internet relay.
2. **Mac Codex adapter and opt-in controls** — stacked on the transport PR. High
   complexity. Owner-only local ingress, supported Codex delivery adapter, local
   task selection, incoming-device approval and revoke controls. Gate availability
   on successful delivery capability detection; do not silently fall back to
   manipulating another app's private storage.

Both require independent Claude and CodeRabbit review, required CI, and a real
two-Mac test before release. Maintainers merge PRs.

## Authentication and scope

Existing SecurePeerChannel authorization is bound to an audio channel; do not
invent a Main-channel identity to bypass this. NearbyNetworkService is join
bootstrap, not a general messaging bus. Add a network-device service reusing
mutual TLS, root-signed device identity bindings and NetworkPolicyCenter.

Authenticate bindings against the actual TLS SPKI hashes. Bind protocol purpose,
network ID/generation, identities and fresh nonces into the handshake. Require
current known network membership at authorization and immediately before dispatch.

A receiver grant maps an opaque capability to one locally selected Codex task.
Scope it to network generation, sender root identity and full installation SPKI
hash. Display names and ephemeral binding IDs are not security identifiers.
Peers cannot enumerate local tasks or supply arbitrary destination task UUIDs.
Revocation fences queued deliveries and closes applicable sessions. Offline
partitions cannot instantly learn revocations they have not received.

Local task registration should work without desktop-private task enumeration:
the initiating Codex task registers its own task ID through the owner-only local
adapter, then ALO presents that registration for explicit local approval. Any
display title is a convenience label, not identity proof. Registering a task does
not approve a remote device; connecting a remote device does not approve every
task. Ship a documented local CLI first so other Codex tasks can register/send
without editing their model, permission settings, or private desktop database.

## Resource bounds and delivery semantics

- Text limit: 16 KiB UTF-8; frame limit: 24 KiB.
- Rate: burst five, sustained ten messages/minute per device/task grant.
- Queue: at most 32 messages and 256 KiB.
- Receiver-monotonic grant/session expiry; UUID message IDs with bounded durable
  deduplication scoped to authenticated sender and grant.
- Acknowledgments distinguish authenticated receipt, local queue acceptance,
  verified delivery and uncertainty. Never label queued content as read.
- Retries preserve message IDs. A crash after CLI enqueue but before receipt
  persistence is uncertain, not permission to enqueue a duplicate automatically.
- Local ingress uses owner-only Unix socket permissions and peer UID validation.
  Execute a pinned Codex binary with argument arrays, never shell interpolation.

## Acceptance tests

Reject nonmembers, wrong network/generation, TLS binding mismatch, cross-protocol
proofs, replay, revoked grants, identity replacement and queued delivery after
the receiving device has applied a membership removal. Test the dispatch fence
concurrently with that local policy update. A partitioned receiver cannot reject
an as-yet-unknown remote revocation; do not claim instantaneous network-wide
revocation. On reconnection, apply received policy changes before dispatching
held messages, revalidate authorization, and reject revoked or expired sessions.
Test oversized/Unicode text, queue floods, expiry, duplicates,
CLI failures and ambiguous crash recovery. Verify the receiver's task choice is
not remotely overridable. Test approved delivery and immediate local revocation
with both Macs outside audio channels, then during music playback without added
audio discontinuities. Verify real existing-desktop-task receipt, not merely a
successful CLI exit. Keep Anytype available for bootstrap until both installations
have the reviewed feature and this test passes.

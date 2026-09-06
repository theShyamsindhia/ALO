# Networks and channels — current implementation contract

Supersedes the Spaces naming and migration sections of sync-network-identity.md.
User decisions: Networks (server) → Channels; public channels are public only to
network members; private channels require explicit access; offline user identity
with unencrypted recovery export and bold warnings. Force old clients to update.
Start fresh; do not import old rooms/Spaces. All current users run onboarding.

## Scope and review graph

Repository: theShyamsindhia/ALO. Base: main (established user release target; there
is no upstream/dev). Head: codex/full-nearby-integration. One integration PR with
independently testable commits because admission/UI/data generation must agree.
No automatic PR merge. No new user-facing tasks; bounded implementation agents
share this task with exclusive file ownership. Main agent owns integration and
Package.swift. Complexity: max.

1. Sync core: reproduced failures → ALOTiming, four timestamps, queue timing,
   truthful measurement age, long-run simulations and live regression gates.
   Independent of new UI; existing native renderers remain adapters.
2. Identity: ALOIdentity root signing key, user ID and signed device binding,
   strict offline verification, scoped Keychain storage, recovery export/import.
   No real-user keys read/exported by coding tools. Native onboarding performs
   new setup only after the user acts. Test ephemeral/temporary namespaces only.
3. Network/channel model: ALORooms immutable owner-signed network manifests,
   signed user membership grants, public/private channel visibility, local store.
   Depends on identity. No Wi-Fi details or sockets in model/persistence module.
4. Admission and UI: new generation requires identity + network membership;
   network creator owns network and auto-created Main channel. UI uses a single
   session API; current room transport carries the selected channel. No legacy
   admission fallback. Onboarding precedes network discovery/join/create.
5. Review + validation: full optimized Mac tests, unsigned iOS build, network
   loopback tests, identity negative tests, UI/model tests, independent security
   review. Strict live timing stays required. Physical two-Mac/Bluetooth
   acceptance is separate and must not be implied by simulation results.

## Identity API contract for parallel implementation

ALOIdentity exports UserIdentity (root secret), PublicUserIdentity (userID String,
publicKey Data), DeviceIdentityBinding (root-signed installation key hash), and
IdentityRecoveryDocument (static human-readable export, strictly parsed import).
The user ID is a domain-separated SHA-256 public-key fingerprint. Network models
store public identity and signatures only. A root signs canonical bytes with
domain separation; verification derives user ID rather than trusting a label.
Implementation agents must coordinate final method names before cross-module use.

## Network authority and invitation flow

An owner-created network has a stable ID, root public identity, name, policy
revision, membership list and channels, signed as one bounded canonical manifest.
Main is created atomically with the network. A public channel is available to all
members; a private channel has an explicit user-ID allowlist. Owner can add users
by verified user ID/public identity. A network invitation must bind a specific
user (or require explicit owner acceptance), never grant membership merely from
knowing a network name. Offline invitation documents/requests can be exchanged
without a server; no network request should upload a root private key.

Peers verify the owner signature and their own/current member grant before
admission, then verify the presenting user's device binding against the actual
TLS installation key and room/channel context. Never advertise private member
details in Bonjour. Highest verified policy revision persists; unknown authority
and rollback fail closed. Offline revocations cannot be globally instantaneous.

## Clean-slate migration boundary

Use a new versioned network/identity data namespace. Do not silently reinterpret
old room IDs as network membership. The migration may remove only enumerated
legacy ALO-owned room/state files and room-selection preferences, after new
storage initialization succeeds. Prefer quarantining exact old files if needed.
Never recursively delete application-support roots, Downloads, received/saved
media, user recovery exports or unrelated settings. Keychain deletion, if needed,
must use exact old ALO service/account scope. Migration is idempotent and retryable.
Do not run the migration against the installed app from this coding session.

## What remains out of scope

Internet relays/cloud accounts, Discord-scale server features, permanent global
availability without reachable peers, voice-enabled-by-remote consent, anonymous
public-channel access bypassing membership, and additional content encryption
without a threat model. Keep existing encrypted transport; user identity is an
authentication/authorization layer, not an invented replacement cipher.

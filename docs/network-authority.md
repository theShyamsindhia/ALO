# Offline network authority

`ALOIdentity` owns the user's root signing identity. `ALORooms` stores only public
identities and owner-signed policy. A network contains members and channels; a
member is a root public user identity, independent of how many devices that user
has. Creating a network atomically creates its owner membership and a public
`Main` channel whose stable UUID is derived from the network UUID.

## Trust and channel access

`NetworkManifest` is immutable and verifies its owner signature during decoding.
The signed body contains its format version, network ID, generation, revision,
name, owner public identity, members with owner/member roles, and channels with
stable IDs, names, visibility, and explicit private-channel allowlists. Fields
are canonicalized into fixed-order binary data with big-endian lengths/numbers;
members, channels, and allowlists are sorted before signing. JSON field order,
whitespace, and ECDSA signature randomness cannot change policy identity.

The limits are 256 members, 128 channels, 80 UTF-8 bytes per name, 128 KiB for the
canonical signed body, and 256 KiB for encoded JSON. Both aggregate byte limits
are checked during manifest construction/decoding, before a policy is signed or
accepted. Duplicate members/channels/channel names, missing or extra owners,
unknown allowlist members, invalid identifiers, and malformed Main channels fail
validation. The owner cannot remove Main or itself.

`authorize(_:channelID:)` and `accessibleChannels(for:)` require the full public
identity to match a signed member. Public channels are accessible to network
members only. Private channels additionally require their explicit allowlist,
with the owner always retaining access. A public identity object alone is not
proof of possession: transport callers must first verify its root-signed device
binding against the actual authenticated TLS installation key. Neither a
discovered name nor a claimed user-ID string grants membership.

## Offline exchange

1. A prospective member exports `NetworkMembershipRequest`, which contains only
   its public identity and the document version.
2. The owner verifies the intended person's public identity over the chosen
   exchange channel and explicitly adds it to the network. This signs a new
   complete manifest revision.
3. The owner exports a `NetworkInvitation` addressed to that granted public
   identity. The recipient imports it with `importInvitation(_:for:)`.
4. First import pins the network's owner and generation. Verify the expected
   owner's fingerprint when exchanging the invitation: a valid self-signature
   by itself cannot establish that the owner is the person the recipient meant
   to join. Subsequent discovery may locate peers but cannot create trust.

Changing the invitation's recipient cannot create a member because the signed
manifest must already contain that exact public identity. Exchanged manifests
contain all public membership and channel policy metadata, including private
channel names and allowlists; private access does not promise hidden metadata.
Never put a manifest or its member details into Bonjour advertisements.

## Persistence and live updates

`NetworkRepository` uses a new `WERAI/networks-v1` or `WERAI-Dev/networks-v1`
directory. Tests inject their own directory. Only canonical UUID filenames are
read as network records. A process lock and file lock serialize comparisons and
atomic record replacement across threads and repository instances. Record reads
are bounded, reject symlinks, and verify signatures. No legacy files or Keychain
entries are read, migrated, or deleted by this repository.

Once a network ID is known, its owner and generation cannot change and revisions
cannot go backwards. Repeating an identical canonical policy is idempotent.
Two valid different policies at the same current revision persist both signed
policies as conflict evidence and quarantine the entire network. Quarantine
survives restart and is not cleared by a later policy. A newly created network
is the supported fresh-start path after an owner forks its authority; automatic
conflict selection or authority reset is intentionally unavailable. A failure
to persist conflict evidence also blocks the originating repository instance.

`trustedManifest(id:)` reads accepted policy without granting channel access.
`acceptUpdate(_:anchoredTo:)` refreshes a network already present on disk and
cannot bootstrap trust. A supplied cache anchor must match the pinned ID, owner,
and generation; the stored latest revision controls rollback checks. Newer
signed updates are stored even when they remove the local member. Membership
queries then deny access, and old invitations cannot restore the old revision.
Local storage integrity assumes the app's policy directory is not maliciously
rewound or erased by another local process; atomic JSON files are not a hardware
anti-rollback ledger.

The session wrapper must notify active sessions after accepting policy, enforce
the newest manifest on every admission/event boundary, stop channels when a
member loses access, and keep using verified owner/generation anchors. Offline
devices cannot learn revocations until they receive newer signed policy; this
model does not claim globally instantaneous revocation or global consensus.

## Tests

`NetworkAuthorityTests` covers canonical round trips, signature tampering,
member/private-channel denial, owner-only mutations, Main invariants, invalid
policies, payload bounds, and member-bound invitations. `NetworkRepositoryTests`
covers fresh scoped storage, trust pinning, rollback, owner/generation changes,
idempotent re-signing, concurrently delivered conflicting policies and persistent
quarantine, live revocation, refresh-only admission, stale owner edits, and
symlink records. All identities are ephemeral and files live in temporary test
directories; no real user identity or recovery document is opened.

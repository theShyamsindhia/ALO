# Room privacy and permissions

The 0.14 integration has two explicit room protocols. Secure rooms never fall
back to legacy transport after admission, permission, or network failure.

## Secure-v2 rooms

| Channel | Protection and exposure |
| --- | --- |
| Nearby discovery | Bonjour metadata is visible locally; private rooms omit member names and playing-media details. Discovery itself is not encrypted. |
| Admission and room coordination | TLS 1.3, per-installation P-256 identity, pinned peer keys, room-bound admission; private rooms additionally prove a 32-byte invite secret. |
| Media clock/control and video | Separate authenticated reliable channels bound to the admitted identities and current broadcaster epoch. |
| Broadcast audio | Session-bound AES-GCM UDP tickets, path proof, bounded expiry, and replay checks. |
| Directed voice | Independent voice-only tickets and fixed recipients authorized by explicit local microphone intent; PCM does not travel through room-control relays. |
| Shared annotations | Authenticated presenter-authoritative events on the media connection; permissions and source generation are checked independently of playback. |
| Installation keys, peer pins, private invites | Device Keychain namespaces, separate for development and production. |
| Retained chat and queue | Local files, without additional app-level encryption; room members receive the shared history. |

Public rooms are encrypted in transit but anyone who can reach them may join.
First contact pins an installation key; it does not independently prove the
person's identity. Reinstalling or resetting an identity can require explicit
trust repair. No local code-signing certificate is required by this protocol;
OS privacy permissions and app signing remain separate concerns.

Receiving Talk/Open Line audio never enables a microphone. Only local Talk,
Invite, or Pick up actions can grant that intent. Leaving, interruption and stale
permission completions revoke it. Device volume controls are local preferences,
not membership revocation. General room administration, invite revocation and
blocking are not provided by the annotation presenter's drawing permissions.

## Legacy compatibility rooms

The following older desktop protocol remains available only when explicitly
selected. It does not inherit secure-v2 identity or encryption guarantees.

| Channel | Public room | Private room | Implementation |
| --- | --- | --- | --- |
| Bonjour discovery | Visible on local network | Discovery metadata remains visible | `MeshRoomBrowser`, `MeshControlPlane.start` |
| Mesh admission | No invite required | Invite-key challenge response | `MeshControlPlane` hello/auth handling |
| Chat, queue, presence, playback ownership, activity messages | Plain TCP | Plain TCP after admission | `MeshControlPlane`, `LocalNetworkParameters.tcp` |
| Talk and Open Line voice | Plain TCP | Plain TCP after admission; may relay through room peers | `publishWalkieTalkie`, `routeWalkieTalkie` |
| Broadcaster media control / clock connection | Plain TCP | TLS 1.2 PSK AES-128-GCM-SHA256 | `RoomMediaSecurity.tcp`, `HostServer`, `Receiver` |
| Broadcaster audio datagrams | Plain UDP | AES-GCM with authenticated context and replay checks | `RoomMediaSecurity`, `SecureDatagram`, `Receiver` |
| Broadcaster video | Plain TCP | TLS using a distinct video-purpose room-derived PSK | `RoomMediaSecurity.tcp(video:)` |
| Local invite keys | Not applicable | macOS Keychain | `RoomStore`, `RoomSecretStore` |
| Local chat and queue history | Local files, no app-level encryption | Local files, no app-level encryption | `RoomStore` |

Invite possession controls admission; it does not encrypt the mesh connection. A
network observer can read mesh chat and voice. Targeting a voice message selects its
recipients but does not make its transit through relays confidential. Room members
share the media secret: media encryption does not provide cryptographic identity
isolation between members or protection from a member who possesses the key.

The current broadcaster is replaceable. It is not a permanent room administrator.
Broadcaster-only queue reordering is a cooperative app UI rule, not a cryptographic
authorization guarantee against modified clients. The app does not currently provide administrator-enforced invite revocation,
admission approval, removal, or blocking. A local mute changes what that Mac hears;
it does not revoke another device's membership. The People voice slider is a local
listening preference saved by persistent device ID, separate from media levels.

Before adding revocation or approval, define a replicated authority and membership
policy, key generations, concurrent-change resolution, reconnect admission, and
migration for existing room peers. Rotating only a local saved key would partition
the room rather than securely revoke a member. Do not confuse a local legacy-key
change with secure-v2 admission or migration.

History retains up to 500 chat events on each Mac; edits and reactions count. There is no enforced seven-day expiry. It is not a
remote deletion guarantee: recipients can retain copies outside the app. Invite
keys and metadata copied to the clipboard are subject to normal macOS clipboard
access. Public/private room labels must not imply that all channels are encrypted.

Voice processing and device-route recovery exist, but echo cancellation quality
still requires real speaker, headphone, and Bluetooth testing. Per-person voice
levels do not substitute for that testing. The opt-in People microphone test records
at most five seconds in memory, using the selected input, and plays it back locally.
It is disabled during microphone transmission or local broadcasting to avoid feeding
test playback into the room. Closing the panel clears the clip and stops capture.

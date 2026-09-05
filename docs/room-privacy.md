# Room privacy and permissions

This describes the desktop `MeshSession` path, audited September 2026. It is not a
claim that every transport implementation in ALOCore is active in the desktop app.

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
the room rather than securely revoke a member. A future encrypted mesh transport
must also authenticate fresh sessions and protect both direct and relayed traffic.

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

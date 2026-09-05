# ALO for iPhone and iPad (iOS 17+)

Open `ALO.xcodeproj` and select the shared **ALO** scheme. It links the repository's local `ALOCore`, `ALONetworking`, and `ALOAppleMedia` products. Signing is disabled; configuring a developer team and device signing is a separate step.

Implemented in the integration branch: explicit nearby scans, first-contact privacy explanation, secure-only room admission, Keychain installation identity/pins/private invite persistence, shared rich chat, participants, read-only queue, local media/voice levels, encrypted audio/video receiving, annotation overlay/interaction, and directed Talk/Open Line. The app advertises chat, receive-audio, receive-video and voice. Video uses a separate authenticated connection and the committed audio timeline; pending capture and presentation work is bounded.

Background audio is enabled only for current, scheduled room playback. Entering background revokes microphone intent and stops discovery/video; paused, stale, muted or absent playback disconnects without a silent keepalive. Foreground rejoin never restarts a microphone. Invite starts the local microphone after permission; Pick up explicitly starts the return direction, while incoming signaling never opens it. These paths require physical-device acceptance before release; compilation and pure policy tests are not proof of audible/background behavior. There are no broadcast, queue editing, or shared playback controls on mobile.

Secure rooms do not expose broadcaster control of another device’s media volume or mute: that authenticated command is not implemented. Each device controls its own media level. Local received-voice mixing is separate and remains available.

Unsigned simulator build (coordinate with other repository builds):

```sh
xcodebuild -project iOS/ALO.xcodeproj -scheme ALO -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Device-to-device encrypted mesh join, private secret rejection, pin persistence, denial/re-enable of Local Network permission, real audible media, microphone consent, VoiceOver, Dynamic Type, and background/route interruptions require runtime/device validation. Compilation alone does not establish these behaviors.

For an **unsigned Debug simulator only**, launch with `--alo-temporary-simulator-identity` to explicitly bypass unavailable Keychain entitlements in the test harness. This generates a fresh in-memory identity and pin store, keeps room credentials/history in memory, and does not read or write saved display-name preferences. A persistent on-screen banner identifies the temporary session. Quit discards all test identity/room data; relaunch does not automatically join a room. Without that flag, Keychain errors remain visible and never silently replace an identity. The flag has no effect in Release or physical-device builds. This mode does not validate real-device Keychain persistence or permission behavior.

Use only isolated test peers and a throwaway test room, not installed production peers: although this simulator's storage is temporary, each launch uses a fresh identity. Peers may retain that identity's Keychain trust pin, participant record, and any messages in their own storage. The harness does not erase or isolate remote peers' data. Merely launching the harness does not scan or join any room.

# ALO

Free, synchronized system audio with optional screen sharing for Macs on the same local network.

ALO creates a persistent local group with synchronized 48 kHz stereo audio, optional
full-screen video sharing, current album artwork, a per-Mac mixer, participant presence, group
chat, and a shared media queue. There is no permanent host: any member can begin
broadcasting, and the room remains available when its creator leaves. Exactly one Mac
broadcasts media at a time while every connected Mac replicates the room's control,
chat, and queue state.

Rooms are public on the local network by default. A creator can instead make a private
room protected by an invite key. Saved room details appear again when the app opens;
private invite keys are stored in the macOS Keychain, while recent chat and durable
queue state are stored locally.

## Requirements

- macOS 14.2 or newer
- Built-in, wired, USB, or Bluetooth audio output
- All Macs on the same Wi-Fi/LAN, with client isolation disabled

## Run the Mac app

Open `dist/ALO.app`. The first screen lists nearby rooms and rooms previously saved
on this Mac:

- Select a nearby or saved room to rejoin it.
- Choose **Create Room** for a new public room, or enable **Private** to generate an
  invite-key-protected room.
- In an open room, choose **Broadcast** to share this Mac's system audio. Any member
  may take over broadcasting; leaving does not delete the room.

The first time a Mac broadcasts, macOS asks for **System Audio Recording Only** permission.
ALO uses one Core Audio tap both to capture the room stream and replace that Mac's immediate
source playback with the synchronized return. Screen sharing separately uses **Screen & System
Audio Recording**. After either first grant, restart ALO if macOS requests it. No speaker output
or audio driver is installed.

After the room connects, the setup window disappears and the room moves into the
menu bar. Click the cat to reveal the compact controls; the same surface grows
downward only when chat, queue, people, or video is requested. A red indicator on the
menu-bar icon marks unread chat without leaving another window on screen. The optional
floating bar can be restored from the window control and remains above your other apps
and across macOS Spaces. In either presentation,
the queue owns its media-link field, chat owns its message composer, and people owns the
per-Mac mixer. Incoming video can expand in the surface or open in its own resizable,
minimizable window. That window supports native macOS fullscreen and can stay pinned
above normal windows across Spaces without interrupting audio. Unread chat is also shown
on the message control.
When the source player publishes track information, the active broadcaster sends
the title, artist, and album artwork to every Mac. Video sharing remains off by
default. Members control their own output, while shared transport actions are applied
by the active broadcaster and replicated to the group.
The menu-bar cat provides the complete room experience without requiring the
floating bar. Its window button toggles the floating presentation at any time. On
listening Macs, keyboard, Touch Bar, headphone, and Control Center
play/pause/previous/next commands are forwarded to the active broadcaster; volume
buttons continue to control the local Mac.
ALO checks its GitHub Releases page shortly after launch and every six hours. Choose
**ALO → Check for Updates…** at any time for a manual check. Room members also advertise
their app version, so seeing a newer member triggers the same official-release check.
Updates are never copied from another room member: ALO downloads the Apple Silicon ZIP
from GitHub, verifies GitHub's SHA-256 digest, the `in.werai.audio` bundle identity,
Developer ID team `R9QFK9NM3Y`, and Gatekeeper acceptance, then replaces and relaunches
the app. macOS asks for administrator approval only when the app's folder requires it.
The interface follows macOS accessibility preferences for reduced motion, reduced
transparency, increased contrast, and the user-selected control accent.

## Build it

The Swift package and app module are `ALO`, shared Swift code is `ALOCore`, and
the executable is `alo`. After packaging, `./alo` runs `dist/alo`; the old
`./werai` launcher forwards to it for compatibility.

### Rebrand compatibility

ALO intentionally retains the `in.werai.audio` production bundle ID, separate
`in.werai.audio.dev` development ID, existing `WERAI` / `WERAI-Dev` data folders,
Keychain services, Bonjour service types, and legacy driver/shared-memory ABI.
Changing those names cosmetically would lose existing permissions, saved rooms,
or interoperability with installed versions. `ALO_*` signing settings are preferred;
existing `WERAI_*` settings remain supported as fallbacks.

The repository is currently still `theShyamsindhia/WERAI`; renaming it to `alo`
requires repository-admin access. Keep the updater on that working repository
until the rename succeeds. The local checkout folder may retain its old name;
it does not affect the app's identity.

Build once on each Mac with Apple's free Command Line Tools:

```sh
xcode-select --install
swift build -c release
```

The terminal interface remains available. On the source Mac:

```sh
./alo host "My Room"
```

On every other Mac:

```sh
./alo join "My Room"
```

The room name is optional. Without one, a receiver joins the first room it finds.

Broadcasting audio uses ScreenCaptureKit and needs **Screen & System Audio Recording**.
ALO requests access when a member first chooses **Broadcast**, before claiming the room's
media timeline. When the active broadcaster also enables video, ALO opens the native macOS
sharing picker. Choose one display or one window; cancelling the picker leaves video off.
The selected content is then streamed to the room.
Every Mac may also ask for **Local Network** access.
Grant recording access in System Settings → Privacy & Security, then use **Restart ALO**
before the first broadcast.

If the Screen Recording switch is already on but macOS still refuses access, quit old
copies of ALO, turn the switch off and on once, and restart the current app. Do not
keep numbered copies such as `ALO 2.app` or `ALO 3.app` in Applications; macOS can
retain stale privacy records for those development builds.

Video sharing intentionally requires the user's Screen Recording consent. ALO excludes
its own windows from the native picker.

Every open room also has a compact walkie-talkie bar. Hold a colored device icon to talk
only to that Mac, or hold the people icon to talk to everyone. **Open line** keeps the selected
voice line open; enable it on both Macs for a two-way line. Choose the active hardware microphone from
the labeled microphone menu. Voice targets stay in ALO's unified popover or optional floating
controls. Incoming speakers highlight clearly. The incoming-audio menu can mute
Music & Video, Voice Lines, or everything. Microphone access is requested only when voice
transmission starts; if it was previously denied, ALO links directly to Microphone settings.

Use **Customize this Mac** on the room picker to change
its generated device name, emoji, color, and optional profile photo. Identity changes persist on that Mac
and propagate to the current room immediately. The walkie bar can be dismissed with its
close button; the same controls remain available from ALO's menu-bar popover.

ALO leaves the selected physical output unchanged. Its private Core Audio tap is the single
authoritative broadcast source: it feeds the room and replaces the broadcaster's immediate
render with the same synchronized return. No additional device appears in the Sound picker.

## Share a ready binary

```sh
./Scripts/package.sh
```

This produces `dist/ALO-macos-universal.zip` for Apple Silicon and Intel Macs. AirDrop
or copy it to the other Macs, unzip it, and open ALO. If Gatekeeper quarantines an
AirDropped ad-hoc-signed development build, build from source on that Mac.

The packaged app uses a stable local designated requirement (`in.werai.audio`) so a
new ALO build does not silently become a different app in macOS privacy settings.

## Mesh room architecture

ALO separates room coordination from the high-rate media stream:

- Every member advertises and discovers the room over Bonjour and maintains direct
  TCP control links to the other members. A deterministic peer-ID rule prevents two
  duplicate links between the same pair of Macs.
- Chat, queue changes, playback metadata, video state, and broadcaster ownership are
  immutable room events. Peers deduplicate events, exchange per-peer version vectors,
  and gossip missing entries until their replicas converge.
- The current broadcaster sends timestamped audio and video directly to all listeners.
  This keeps one shared media timeline without making the room creator a permanent
  server. If the broadcaster leaves, the room stays connected and silent until any
  remaining member chooses **Broadcast**.
- Concurrent attempts to take over broadcasting are resolved deterministically, so all
  replicas settle on the same source. A later take-over supersedes the prior claim.
- Queue removals are replicated as tombstones, so an old add event cannot resurrect a
  removed item after a temporarily disconnected peer returns.
- Each Mac retains durable queue state and up to 500 chat messages from the last seven
  days. Transient broadcaster ownership is deliberately not restored after relaunch.

Public rooms are discoverable and joinable by devices on the LAN. Private rooms require
the same room ID and invite key; peers prove possession during the control handshake.
Private admission prevents an uninvited ALO peer from joining, but room traffic is not
yet end-to-end encrypted, so use both room types only on a trusted local network.

## How synchronization works

- Eight rapid clock samples are taken when a Mac joins, followed by a continuous sample
  every second. A low-latency clock model estimates both offset and drift while rejecting
  Wi-Fi spikes.
- The room establishes one shared playout target before audio begins. Once streaming starts,
  that timeline is locked, so a joining Mac adopts the room's timing instead of interrupting
  everyone already listening.
- Output-device latency and render headroom are measured per Mac. Remaining error is
  corrected 20 times per second with a smoothed varispeed adjustment capped at 1%.
- Each receiver watches the audio render clock while packets are still arriving. If a
  CPU spike stops that clock for 250 ms, or pushes playback more than 100 ms ahead or
  behind the room timeline, it flushes stale scheduled audio and re-anchors itself.
- Play and pause in the room bar are shared controls. A member's request is sent to the
  current broadcaster, applied to its active system media player, and rebroadcast to the room.
- Listening Macs publish the room as their active macOS Now Playing session, allowing
  system and accessory transport buttons to use the same broadcaster-authoritative command path.
- Video follows the same room target and capture timestamps as audio, preserving lip sync.
- Audio uses about 1.54 Mb/s per receiving Mac. Video targets about 4 Mb/s at up to
  1280×720 and 30 fps using Apple’s hardware H.264 encoder.
- Packet loss becomes a short silence rather than delaying every receiver.
- Room traffic is LAN-only and currently unencrypted. Use it only on a trusted network.
- Spotify artwork is resolved once per track through Spotify’s public HTTPS artwork
  endpoint; no Spotify account token is used. Other players use macOS Now Playing data
  when the system makes it available.
- Bluetooth format and latency transitions are detected and the output graph is rebuilt
  without discarding the voice jitter cushion. Bluetooth adds device latency, so ALO is
  not intended for live musical performance.

## Verify

Run the complete test suite:

```sh
swift test
```

Run only the fast, deterministic timing model:

```sh
swift test --filter RoomScaleLatencyReproductionTests
```

Run the realistic single-Mac room test:

```sh
swift test --filter LoopbackRoomScaleTests
```

Run the focused single-Mac mesh tests:

```sh
swift test --filter MeshRoomTests
```

Run the combined live-socket scenario and repeatable partition/restart simulations:

```sh
bash Scripts/test_room_scenarios.sh 3
```

This keeps per-run logs and checks mixed media/voice/chat traffic, repeated late
joins, disk restoration, delayed links, offline edits, and convergence after
network partitions. See [scenario coverage and hardware-test limits](docs/room-scenario-testing.md).

For automated two-Mac QA without UI automation, save or join the room once in
the app on each Mac, then run the signed app binary on either Mac:

```sh
/Applications/ALO.app/Contents/MacOS/alo room "Room Name"
# Start as broadcaster when no one is sharing:
/Applications/ALO.app/Contents/MacOS/alo room "Room Name" --broadcast
# Join first, then claim the newer broadcaster epoch for a handoff test:
/Applications/ALO.app/Contents/MacOS/alo room "Room Name" --take-over
```

This opens the same mesh control plane, receiver, clock synchronization, and
audio renderer as the GUI. Lines prefixed with `ALO_QA` expose connection,
playback, peer-version, and participant state for a test harness.
Grant Screen & System Audio Recording from the GUI on that same Mac before using
`--broadcast` or `--take-over`; macOS cannot complete the first consent prompt from
an SSH-only session.

This suite opens real loopback TCP listeners for three independent peers and verifies
that the control mesh remains usable after the creator disconnects. It also checks
public admission, successful private admission, rejection with a wrong private key,
replica/version-vector convergence, concurrent broadcaster conflict resolution, queue
tombstones, and bounded chat/queue persistence. It does not advertise on the LAN,
capture audio, prompt for recording permission, or write test credentials to Keychain.

The loopback suite starts the real host plus headless TCP and UDP peers on one Mac. It
compares an unconstrained room, one receiver on a constrained link, eight receivers
with unbounded buffering, and eight receivers with bounded buffering. It also exercises
late-playback detection, receiver telemetry, CPU-stall recovery, shared play/pause
control, and automatic hard resynchronization. It does not need Screen Recording
permission or additional Macs.

Useful output from the loopback test includes:

- **Final packet age:** must remain below the room's active playout delay.
- **Audible lateness:** should remain at zero; a positive value means playback missed
  the shared timeline.
- **Arrival skew:** shows how far receivers diverged while receiving the same packet.
- **Packets delivered:** exposes the audio-quality cost of dropping stale packets.
- **Resync commands:** confirms that the host detected late receivers and requested
  live recovery.

### Fine-tune synchronization

Change one control at a time and compare it with the unbounded baseline in
`LoopbackRoomScaleTests`:

- `RoomTiming.defaultPlayoutDelayNanos`, `maximumPlayoutDelayNanos`, and
  `timingStepNanos` control the initial shared room buffer before its timeline locks.
- `SynchronizedPlayer.hardResyncThresholdNanos` controls when gradual varispeed
  correction gives way to a hard re-anchor.
- `PlaybackWatchdog.stallThresholdNanos` controls how long an active receiver's render
  clock may stop before it re-anchors. `activePacketWindowNanos` prevents an intentionally
  paused source from being mistaken for a stalled client.
- Every accepted play or pause command broadcasts an explicit hard-resync command. This
  makes the menu-bar, floating-bar, and hardware media controls a manual recovery path:
  pause and play once to re-anchor every receiver to the shared capture timeline.
- `HostServer`'s `boundedLatest(maxInFlight:)` default controls how many packets each
  receiver may have outstanding before stale pending audio is replaced.
- `linkBitsPerSecond`, peer count, callback count, and callback cadence in
  `LoopbackRoomScaleTests` define repeatable congestion scenarios.

After tuning, run all three focused suites at least twice, followed by `swift test`. A useful
change should keep the direct eight-peer control lossless, reduce packet age and audible
lateness in the constrained eight-peer case, and avoid excessive hard resynchronizations.

The broader tests also cover audio and video framing, room media and queue state, mixer
state, packetization timing, clock offset and drift, adaptive jitter handling, malformed
input, and fragmented messages.

## GitHub builds and releases

Publishing a GitHub Release runs **Build Apple Silicon app** on an Apple Silicon GitHub
runner. The workflow imports the repository's encrypted Developer ID certificate into an
ephemeral keychain, enables the hardened runtime, submits the app and disk image to Apple's
notarization service, staples the approval tickets, and verifies Gatekeeper acceptance.
Manual workflow dispatch remains available for signing diagnostics.

The repository must provide `DEVELOPER_ID_P12_BASE64` and
`DEVELOPER_ID_P12_PASSWORD` as Actions secrets, plus
`APP_STORE_CONNECT_API_KEY_BASE64` as an Actions secret. Configure
`ALO_CODESIGN_IDENTITY` (legacy `WERAI_CODESIGN_IDENTITY` is also accepted),
`APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`, and
`APP_STORE_CONNECT_ISSUER_ID` as Actions variables. Use an App Store Connect
team key (Developer access or higher), because individual API keys cannot submit
software to Apple's notarization service. The imported P12 must contain the
**Developer ID Application** identity and its private key.

To publish a downloadable build on the repository's **Releases** page:

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Commit and push the version change to `main`.
3. Create a tag matching `CFBundleShortVersionString` exactly, with an optional leading
   `v`, and publish a GitHub Release for that tag. For example:

   ```sh
   gh release create v0.9.0 --target main --generate-notes
   ```

Publishing the release automatically attaches notarized and stapled
`ALO-macos-arm64.zip` and `ALO-macos-arm64.dmg` downloads to the release.

If an older ad-hoc-signed copy appears enabled under **Privacy & Security → Screen &
System Audio Recording** but still cannot start a room, remove the old ALO entries,
install the newly signed release in `/Applications`, launch it, and grant recording access
again. This one-time reset replaces the stale permission record created by the old build.

ALO 0.12.1 and newer do not install or use the old `ALO Room` audio device. If a prior
test build installed it, remove that one legacy copy in Terminal and restart Core Audio:

```sh
sudo /bin/rm -R /Library/Audio/Plug-Ins/HAL/ALORoom.driver
sudo /usr/bin/killall coreaudiod
```

## License

MIT. No paid service, account, server, or third-party runtime dependency.

# WERAI

Free, synchronized system audio with optional screen sharing for Macs on the same local network.

WERAI creates a private local room with synchronized 48 kHz stereo audio, optional
screen sharing, current album artwork, a per-Mac mixer, participant presence, and
group chat. Everyone can also add media links or a detected current track to a shared
room queue; the host opens the selected item so its audio remains the synchronized
source. Audio uses timestamped PCM over UDP; hardware-encoded H.264 video, chat,
queue updates, artwork, and presence use TCP. Every Mac—including the source—plays
against the same 250 ms monotonic-clock timeline.

## Requirements

- macOS 14.2 or newer
- Built-in, wired, or USB audio output
- All Macs on the same Wi-Fi/LAN, with client isolation disabled

Bluetooth output is not recommended because its latency can change while playing.

## Run the Mac app

Open `dist/WERAI.app`, then choose one role:

- **Start a room** on the Mac whose system audio you want to send. Screen sharing is off by default.
- **Join a room** on every other Mac, then choose the nearby room.

After the room connects, the setup window disappears and the room moves into the
menu bar. Click the waveform to reveal the compact controls; the same surface grows
downward only when chat, queue, people, or video is requested. A red indicator on the
menu-bar icon marks unread chat without leaving another window on screen. The optional
floating bar can be restored from the window control and remains above your other apps
and across macOS Spaces. In either presentation,
the queue owns its media-link field, chat owns its message composer, and people owns the
per-Mac mixer. Video can expand in the surface or enter a screen-filling view, then return
to the controls without interrupting audio. Unread chat is also shown on the message control.
When the source player publishes track information, the host sends
the title, artist, and album artwork to every Mac. Screen sharing remains off by
default. Guests can control their own output, while the host can control every Mac.
The menu-bar waveform provides the complete room experience without requiring the
floating bar. Its window button toggles the floating presentation at any time. On joined client
Macs, keyboard, Touch Bar, headphone, and Control Center play/pause/previous/next
commands are forwarded to the host; volume buttons continue to control the local Mac.
The interface follows macOS accessibility preferences for reduced motion, reduced
transparency, increased contrast, and the user-selected control accent.

## Build it

Build once on each Mac with Apple's free Command Line Tools:

```sh
xcode-select --install
swift build -c release
```

The terminal interface remains available. On the source Mac:

```sh
./werai host "My Room"
```

On every other Mac:

```sh
./werai join "My Room"
```

The room name is optional. Without one, a receiver joins the first room it finds.

Audio-only rooms ask only for the system-audio access needed by macOS. WERAI asks for
**Screen & System Audio Recording** only when the host first enables video. Every Mac may
also ask for **Local Network** access. Grant access in System Settings → Privacy &
Security, then use **Restart WERAI** if macOS asks you to restart it.

If the Screen Recording switch is already on but macOS still refuses access, quit old
copies of WERAI, turn the switch off and on once, and restart the current app. Do not
keep numbered copies such as `WERAI 2.app` or `WERAI 3.app` in Applications; macOS can
retain stale privacy records for those development builds.

Press Control-C on the source to stop streaming. macOS then removes the private audio
tap and restores normal direct playback.

## Share a ready binary

```sh
./Scripts/package.sh
```

This produces `dist/WERAI-macos-universal.zip` for Apple Silicon and Intel Macs. AirDrop
or copy it to the other Macs, unzip it, and open WERAI. If Gatekeeper quarantines an
AirDropped ad-hoc-signed development build, build from source on that Mac.

The packaged app uses a stable local designated requirement (`in.werai.audio`) so a
new WERAI build does not silently become a different app in macOS privacy settings.

## How synchronization works

- Eight rapid clock samples are taken when a Mac joins, followed by a continuous sample
  every second. A low-latency clock model estimates both offset and drift while rejecting
  Wi-Fi spikes.
- The room shares one adaptive playout target. It stays at a safe 250 ms on a healthy LAN
  and grows only when the weakest active connection reports sustained jitter. Reductions
  happen slowly so the room never snaps backward in time.
- Output-device latency is measured per Mac. Remaining error is corrected 20 times per
  second with a smoothed varispeed adjustment capped at 0.2%.
- Each receiver watches the audio render clock while packets are still arriving. If a
  CPU spike stops that clock for 250 ms, or pushes playback more than 100 ms ahead or
  behind the room timeline, it flushes stale scheduled audio and re-anchors itself.
- Play and pause in the room bar are shared controls. A participant's request is sent
  to the host Mac, applied to its active system media player, and rebroadcast to the room.
- Joined clients publish the room as their active macOS Now Playing session, allowing
  system and accessory transport buttons to use the same host-authoritative command path.
- Video follows the same room target and capture timestamps as audio, preserving lip sync.
- Audio uses about 1.54 Mb/s per receiving Mac. Video targets about 4 Mb/s at up to
  1280×720 and 30 fps using Apple’s hardware H.264 encoder.
- Packet loss becomes a short silence rather than delaying every receiver.
- Room traffic is LAN-only and currently unencrypted. Use it only on a trusted network.
- Spotify artwork is resolved once per track through Spotify’s public HTTPS artwork
  endpoint; no Spotify account token is used. Other players use macOS Now Playing data
  when the system makes it available.
- Bluetooth output is less predictable than built-in, wired, or USB speakers. This is
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
  `timingStepNanos` control the adaptive shared room buffer.
- `SynchronizedPlayer.hardResyncThresholdNanos` controls when gradual varispeed
  correction gives way to a hard re-anchor.
- `PlaybackWatchdog.stallThresholdNanos` controls how long an active receiver's render
  clock may stop before it re-anchors. `activePacketWindowNanos` prevents an intentionally
  paused source from being mistaken for a stalled client.
- `HostServer`'s `boundedLatest(maxInFlight:)` default controls how many packets each
  receiver may have outstanding before stale pending audio is replaced.
- `linkBitsPerSecond`, peer count, callback count, and callback cadence in
  `LoopbackRoomScaleTests` define repeatable congestion scenarios.

After tuning, run both focused suites at least twice, followed by `swift test`. A useful
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
`WERAI_CODESIGN_IDENTITY`, `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`, and
`APP_STORE_CONNECT_ISSUER_ID` as Actions variables. Use an App Store Connect
team key (Developer access or higher), because individual API keys cannot submit
software to Apple's notarization service.

To publish a downloadable build on the repository's **Releases** page:

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Commit and push the version change to `main`.
3. Create a tag and publish a GitHub Release for that tag, either in GitHub or with:

   ```sh
   gh release create v0.9.0 --target main --generate-notes
   ```

Publishing the release automatically attaches notarized and stapled
`WERAI-macos-arm64.zip` and `WERAI-macos-arm64.dmg` downloads to the release.

If an older ad-hoc-signed copy appears enabled under **Privacy & Security → Screen &
System Audio Recording** but still cannot start a room, remove the old WERAI entries,
install the newly signed release in `/Applications`, launch it, and grant recording access
again. This one-time reset replaces the stale permission record created by the old build.

## License

MIT. No paid service, account, server, or third-party runtime dependency.

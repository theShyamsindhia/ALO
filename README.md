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

After the room connects, the setup window disappears and one room bar floats above
your other apps and across macOS Spaces. Its compact row keeps the room and four core
tools available. That same continuous glass surface grows upward only when needed:
the queue owns its media-link field, chat owns its message composer, and people owns the
per-Mac mixer. Video can expand in the surface or enter a screen-filling view, then return
to the room bar without interrupting audio. Unread chat is shown on the message control.
When the source player publishes track information, the host sends
the title, artist, and album artwork to every Mac. Screen sharing remains off by
default. Guests can control their own output, while the host can control every Mac.
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

- Eight rapid clock samples are taken when a Mac joins; the lowest-latency samples are
  combined to reject Wi-Fi spikes.
- Group latency is intentionally 250 ms. Output-device latency is measured per Mac,
  and long-running clock drift is corrected gradually by at most 0.2%.
- Video uses the same capture timestamps and 250 ms target as audio, preserving lip sync.
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

```sh
swift test
```

The tests cover audio and video framing, room media and queue state, mixer state, MTU
size, packetization timing, clock-offset calculation, malformed input, and fragmented
messages.

## License

MIT. No paid service, account, server, or third-party runtime dependency.

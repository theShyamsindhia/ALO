# Native network browser and paired dev sync validation

Base: main c07a605 (0.15.1). Branch: codex/network-browser-sync-diagnostics.
One reviewable PR contains native browser presentation and sync evidence needed
for this investigation. Playback fixes require an observed failure and regression
test before changing the controller; UI work is independent of audio behavior.

## Presentation

Keep approved name/recovery onboarding unchanged. Use compact macOS network rows,
separate channel detail, contextual menus and explicit approval sheets. Retain
signed membership checks. Verify empty, long-name, pending, dark/light and compact
states with actual native renders, not only bitmap existence assertions.

## Paired physical test

1. Quit production ALO on both Macs. Do not delete its data or identities.
2. Install matching ALO Dev commit with isolated bundle ID, identity and network
   stores. Optional game records/packs and icon stores are still shared: exclude
   those features from this test rather than claiming complete data isolation. Record installed
   source revision, binary SHA, OS and output type. Do not use Developer ID or run
   local signing commands; the installer preserves the linker's executable.
3. Create an isolated dev network/channel. Shyam broadcasts the Spotify audio
   already playing; Raj receives. Confirm both processes are dev, not release.
4. Capture per-second `in.werai.audio.dev` / `synchronization` unified-log samples
   on both sides for uninterrupted playback, then a separate leave/rejoin trial.
   Annotate output changes, calls, pause/resume and deliberate resync with times.
5. Compare fresh software render error, clock offset/RTT, buffer and reported output
   latency, missing samples, late packets and resync counts. Healthy connection or
   a healthy last sample does not prove an entire run was aligned.
6. Export retained anonymous incidents after recovery. No identity keys, channel
   names, device names, source audio or media metadata in shared diagnostics.
7. Software render clocks do not measure acoustic/earphone transport latency.
   A listening observation is separate evidence; do not claim physical precision
   from the software trace or from independent-clock simulations alone.

## Acceptance

- Regression first for every confirmed defect, including incident hysteresis.
- Bounded traces/incidents through missing samples and recovery; privacy tests.
- Existing deterministic clock, route, rejoin, call and strict live timing tests
  remain required. No threshold relaxation to manufacture a passing result.
- Claude/CodeRabbit review and CI before a ready PR. Maintainer owns merge.
- Document observed results and untested hardware explicitly; no claim that all
  possible sync failures are eliminated.

## Coordination

The user selected the Anytype Agents / alo chat for Shyam/HELD coordination.
The local API supports SSE messages/stream, but the connector may buffer rather
than deliver incremental events. An SSE-capable runner can subscribe with bounded
reconnect/deduplication; otherwise the other agent's 30-second product watcher is
a fallback, not an event subscription. Never expose local API credentials.

## Validation checkpoint (2026-09-07)

- `ce6cb97`: all three GitHub verification jobs passed, including strict Mac
  tests, the unsigned distribution build and iOS simulator build (run 34125484387).
- Diagnostic regressions reproduce early recovery at intermediate drift and
  expected pause/leave gaps evicting genuine incidents; both require RED→GREEN.
- Native fixtures cover normal, long-name, empty, pending and owner-with-no-channel
  layouts at two sizes in light/dark appearances. Inspect the resulting renders;
  bitmap creation alone does not establish usable layout.
- Raj runs the isolated dev app; Shyam's Swift 6.1.2 cannot compile this branch's
  default-isolation flag. A matching prebuilt arm64 archive was sent through the
  agreed Anytype chat with SHA256 verification instructions. A temporary LAN-only
  transfer timed out from Shyam and was stopped without changing network settings.
- Physical playback validation is still pending. These results do not establish
  the cause of the reported audible drift or claim a playback fix.

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
   source revision, binary SHA, OS and output type. The user approved certificate-free
   ad-hoc signing of ALO Dev on September 7. Seal the completed bundle after all
   resources/plist changes; verify with `codesign --verify --deep --strict`.
   Developer ID/notarization are not used. Ad-hoc validity is not Gatekeeper trust:
   downloaded dev builds may require normal first-open approval. Never disable
   system-wide security or remove quarantine as part of this installer.
   The plist records the pre-sign input binary hash; compare the separately reported
   signed executable hash between Macs (embedding that hash would change the signature).
   Different OS signing tools can produce different signature bytes: in that case
   compare the input binary hash and revision, and strictly verify each seal; a
   signed-hash mismatch alone does not establish differing application code.
   Prior dev bundles are deliberately retained for recovery, not automatically
   deleted. The installer prints their durable backup location for manual cleanup.
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
- A missing-measurement incident means timing evidence was unavailable, not proof
  of an audible failure. Keep immediate gaps: delaying their recording to wait for
  slower now-playing metadata could hide brief real stalls. Explicitly known
  pauses are notice-only; ambiguous missing samples stay unknown. Under retention
  pressure, preserve measured drift before discarding older missing-only evidence.
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
- The original transferred ce6cb97 bundle failed strict resource-seal validation.
  Re-sealing that exact bundle with certificate-free ad-hoc signing passes strict
  validation and launches on both Macs. The installed signed executable hashes
  match. Shyam confirmed identity setup; joining the existing test network and
  paired playback remain unconfirmed.

## Timing evidence must have an independent reference

The combined six-minute simulation separates host monotonic time, capture sample
time, each receiver's monotonic and output-sample clocks, network arrival events,
and reported output latency. It uses the production estimator and rate-controller
math but is not a hardware or acoustic measurement. With bounded small path
asymmetry, the initial run stayed within 1.54 ms of inter-output content separation.
An intentionally adverse additional 80 ms in one direction produced 56.82 ms
separation while the maximum reported render residual was only 14.01 ms.
This is a diagnostic blind spot, not evidence that the users' Wi-Fi has that delay.

Do not "fix" that adversarial case by teaching an estimator the simulation's
hidden reference clock. Round-trip timestamp exchanges cannot uniquely identify
the one-way delay. [RFC 5905](https://www.rfc-editor.org/rfc/rfc5905.html) separates
offset, delay, dispersion and jitter; a small residual relative to an uncertain
clock is not proof of aligned outputs. Tests must distinguish estimated health
from the independent reference and avoid claiming an unconditional sync guarantee.

The offline Apple audio graph probe also invalidated the assumption of zero
downstream processing delay: player → varispeed → mixer produced approximately
0.99–1.35 ms of impulse delay at rates 0.99/1/1.01 and outputs 48/44.1 kHz.
Inter-impulse intervals followed the requested rate. That small constant offset
alone does not explain the larger reported drift. Apple's
[hardware presentation latency](https://developer.apple.com/documentation/avfaudio/avaudioionode/presentationlatency)
and [downstream pipeline latency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency)
are distinct measurements; neither an offline graph nor a simulated route proves
the acoustic latency of Bluetooth earphones.

## Reproduced recovery and health defects

- A production `SynchronizedPlayer` in an offline native graph kept an injected
  prior 1.01 rate for approximately 1.5 seconds while PCM and player sample time
  advanced but the render host timestamp was unavailable. The new controller
  retains correction through brief gaps, then clears it on the next maintenance
  call after 500 ms without usable timing. At the 1% correction limit, that grace
  represents about 5 ms of extra correction if maintenance keeps running; it is
  not a hard bound when the maintenance queue itself stalls. A fresh sample after
  a long stall must not replay the old smoothed correction. The test seeds the
  prior audio-unit rate; it does not establish how often real hardware enters
  this condition.
- Fresh 70 ms render drift incorrectly passed diagnostics because they used the
  player's emergency reset threshold instead of the monitor's 40 ms warning /
  20 ms recovery thresholds. Both views must use the same health tolerances.
- An 82 ms RTT with a small inferred residual also passed. Elevated or missing
  RTT now withholds confidence, including on the broadcaster using the exact
  listener's existing fresh, authenticated telemetry. The best-RTT window can
  retain older low samples: this conservative warning is not a complete clock
  uncertainty model and does not eliminate every path-transition blind spot.

These failures were reproduced before production fixes. Regression passes,
independent review and physical playback validation remain release gates; do not
treat the implementation or this document as proof that those gates have passed.

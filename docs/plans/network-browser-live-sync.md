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
reconnect/deduplication. Shyam has disabled scheduled polling; do not re-enable it
without his request. The paired task should remain active under an explicit goal
and report concrete progress or blockers. Every outgoing coordination message must
use a structured Shyam mention. Never expose local API credentials.

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
  match. Both dev identities subsequently joined the test network, following an
  owner approval whose public fingerprint was independently matched. Both devices
  are visible in Main. Raj's dev Diagnostics confirms one reachable remote peer,
  but still reports "No broadcaster" despite Shyam reporting Spotify broadcasting.
  The paired playback baseline has therefore not begun; local Spotify playback,
  membership, and TLS connectivity must not be counted as successful media delivery.
  Keep this baseline distinct from the newer source fixes until both installed
  builds are updated and their revisions verified.
- `7dc63e3`: Mac and iOS builds passed; required Mac tests failed. The full CI run
  exposed a screen-diagnostics fixture missing newly required peer RTT, an offline
  player fixture entering an unrelated late-packet reset on a slow runner, and a
  download-monitor XCTest callback overfulfilling after the test ended. These are
  release blockers, not waived checks. Strict live-timing thresholds remain unchanged.
- `1a2a07a`: all three required verification jobs passed (run 34139725578).
  The combined local checkpoint passed 83 Swift Testing cases and 18 XCTest
  cases, including strict live fan-out timing and the previously failing fixtures.
  Review follow-ups and physical validation remain open; this is not a release.

## First paired baseline and hardware-clock investigation

Both installed apps still used matching `ce6cb97` code. Shyam's process changed
before the confirmed broadcast; its earlier no-broadcaster state is superseded,
not evidence of a continuing discovery failure. The receiver subsequently saw
incoming packets and the app reported active playback. Its recorded drift was
unavailable, capture-to-receive transit variation was approximately 106–248 ms,
and the trace showed 20 late packets and two realignments without further growth.
Control RTT was approximately 4 ms. Transit variation includes sender queues and
capture scheduling, so it is not by itself a measurement of Wi-Fi delay.

The sender and receiver overlapped for approximately 114 seconds beginning at
15:40:23 UTC. Both logged an explicit paused state at approximately 15:42:18 UTC;
the cause of the pause is not established. The planned ten-minute uninterrupted
test therefore did not complete. A ten-minute log process is not ten minutes of
validated playback. Neither the started/recent-packets flag nor these reports
prove nonzero PCM, audible output, or acoustic alignment.

The secure host did not populate submission counters, so its displayed `0/0`
was unavailable instrumentation, not proof of zero delivery. Similarly, the
receiver's displayed 550 ms buffer was a recommendation rather than the actual
scheduled channel delay. These distinctions must be explicit in diagnostics.

After that baseline, a separate silence-only native output probe on Raj's Mac
observed 150 valid, advancing player timestamps. Every host timestamp was ahead
of the observation taken after reading it, by 11.59–22.25 ms. Output was 48 kHz,
512 frames per buffer, with 48 safety-offset frames. No microphone, capture,
route, volume, network, or installed-app changes were made. The existing drift
estimator rejects all future host timestamps. This establishes a real hardware
timestamp behavior requiring a regression, but the app's exact rejection gate
must still be confirmed with bounded local observations before changing policy.

Apple's [AudioDeviceIOProc contract](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc)
distinguishes the current I/O-cycle timestamp from the time output will reach
the hardware. Do not equate a render timestamp with callback receipt time or
accept arbitrary future timestamps: any policy allowance needs a measured,
bounded scheduling basis and future/stale/invalid control tests.

The next instrumented candidate passed 114 Swift Testing cases and 19 XCTest
cases locally (`typed-confidence-telemetry-green.log`). Its fixed-cardinality,
local-only observations distinguish invalid timestamps, future render times,
stale packets and missing anchors; they do not alter estimator acceptance.
Three additional recovery regressions failed first and now pass: peer IDs cannot
collide with the local renderer's identity, duplicate IDs cannot overwrite an
unhealthy verdict, and changing to listener clears old remote recovery state.
This is a test checkpoint, not completed two-Mac validation. The old Raj Dev app
was normally quit before installing this candidate; production ALO stays closed.

### Installed instrumented checkpoint

- Candidate: `8993691b34e8bd0e100f534e8755af3114ba783b` (not a release).
- Installed signed executable SHA256:
  `2f7f8eccdcd693cc782d1c88af1fd74439be287eb1fe9dda5e660b263dcc7984`.
- Matching archive SHA256:
  `38b4c58261b3da7c5536c2fbae73ae87383b7298a8a3730a26d89b00ca458f44`.
- Archive delivered through the agreed Anytype chat, with a verified structured
  Shyam mention and file attachment. Remote installation is not yet confirmed.
- Raj's startup is waiting in `SecItemCopyMatching` while loading the existing
  dev identity. A process sample confirms this is before network startup. Normal
  Keychain approval must be completed by the user; do not reset keys or change
  access controls to get a test running. No paired playback evidence exists for
  this candidate yet.
- The subsequent `e9c527f` change only repairs the shell regression fixture's
  process-substitution lifetime issue observed on CI; it does not change the
  shared app binary.

Any later future-render fix must preserve the raw render timestamp for phase
calculation while keeping freshness and rate holdover on a nonfuture observation
basis. Past render timestamps must retain their actual age: repeatedly polling
an old timestamp must never manufacture fresh evidence. Exercise the production
player, not just a copy of its mathematical branch, and keep missing/invalid,
stale, route-change, overflow and bounded-holdover controls.

History identifies the strict future-time rejection at commit `cfdf432`
(0.14.9), when inline playback phase arithmetic moved into `RenderDriftEstimate`.
Its parent used the raw render host timestamp for phase correction and stamped
measurement freshness with polling time. The extraction added `now >= render`
and aged reports from render time instead. This is a concrete regression path
consistent with the hardware probe, not proof that every historical dropout had
that cause. Retain the extraction's overflow, finite-value, stale-sample and newer
capture-clock protections; do not restore the older unchecked arithmetic.

The opt-in `LiveProductionRenderProbeTests` then exercised the actual
`SynchronizedPlayer` with three seconds of zero PCM on Raj's real default output.
All 135 maintenance polls reported `render-ahead-of-poll`, with 134 advancing
sample observations, zero late packets and zero resyncs. Representative signed
render ages at observation were −15.639, −15.407 and −19.662 ms, with a 10.667 ms
output buffer and 1 ms safety offset. This confirms the failing gate in the
production playback class, independently of Keychain or the paired app setup.
It does not prove acoustic alignment or network delivery. The probe is explicitly
opt-in and uses no identity, network, microphone, capture, route or volume change;
default CI must not require access to a physical audio output.

Before changing playback policy, the same opt-in production-player probe added
expectations for more than 20 accepted measurements and a nonnil drift/age report.
Both failed at runtime (`production-future-render-red.log`): 135 future-time
rejections, zero accepted measurements, no drift report, still 134 advancing
sample observations and zero late packets/resyncs. The other 31 cases in that
batch passed after the diagnostic fixes. Preserve this RED evidence alongside the
later GREEN run; hardware tests must not claim two-device acoustic sync.

### Bounded future-time correction: local GREEN

`future-render-green.log` records 94 Swift Testing cases plus 14 XCTest cases
passing. The unchanged useful-measurement/report assertions now pass on real
output: 126 accepted measurements, eight expected pre-timeline startup polls,
133 advancing sample observations, zero future-time rejections, zero late packets
and zero resyncs. Estimated local software phase error ranged from 2,624 to
14,083 ns; these numbers are not two-device or acoustic accuracy measurements.

The acceptance allowance is derived from two measured I/O buffers plus the
device safety offset and an empirical 2 ms margin. Geometry must be valid and
the computed allowance must fit a 250 ms engineering horizon; missing or
unsupported geometry retains strict future-time rejection. This is not an Apple
guarantee or an acoustic/Bluetooth latency model. The current route yielded a
24.333 ms allowance. A 4,096-frame/44.1 kHz regression prevents unnecessarily
rejecting plausible larger buffers. Route geometry refreshes independently of
whether a transient zero presentation-latency measurement is retained.

The raw render timestamp still defines phase; `min(render, observed)` defines
freshness for reports and rate holdover. Both zero-lead and 20 ms future-lead
six-minute simulations pass the original normal-path bound, while the asymmetric
network scenario still exposes its documented clock-uncertainty limitation.
Four diagnostic review findings are fixed as well: distinguish measured
realignment, populate legacy observations, snapshot one player consistently at
cutover, and reset sample-delta continuity after intentional resynchronization.
Paired Spotify validation, final reviews/CI and native UI work remain pending.

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

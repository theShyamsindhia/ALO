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

## Fixed dev candidate deployment checkpoint (2026-09-07)

- Installed revision `6f7d33c5b6acd04f70162484b36535e8dced306d` on Raj's Mac;
  strict code-signature verification and canonical icon transparency passed.
- Signed executable SHA256:
  `8ca572d7ecd5f9782f23db0626f9756c00b2a707d2e3e4d4094118b23572c300`.
  Matching archive SHA256:
  `fb61dbacc3b95f13a0f0bf4f44b1587c33858dffcd66a11bb1971bc7923a2a04`.
  Sent the archive through the existing Anytype coordination chat with a verified
  Shyam mention and attachment; remote installation is not yet confirmed.
- Production ALO remains stopped. The updated Dev process is waiting in
  `SecItemCopyMatching` while loading its existing identity. Normal user-owned
  Keychain approval is required; no identity reset or security bypass was used.
- The previous diagnostic process was terminated for this dev-only replacement
  after normal termination did not finish its blocked Keychain read. Existing
  identity/network data was preserved.
- CodeRabbit's committed-diff review is clean. Claude found additional snapshot,
  lifecycle-continuity, and rejected-measurement consistency issues; these are
  being reproduced and addressed before final review. CI run `34144640529` for
  this exact revision passed all three jobs, including required Mac tests and
  repeatable room scenarios. This is a test candidate, not a release or paired-sync pass.

The follow-up regression run (`future-reporting-red.log`) failed at runtime with
10 assertions: rejected latency kept a future allowance, four explicit player
stop paths retained old sample continuity, the host omitted/mixed local timing,
and transmitted receiver timing combined the audible predecessor with successor
hardware. The last case reported a 480 ms hardware floor / 485 ms recommended
delay instead of the audible track's 250 ms values. Those are concrete test
results, not a claim that this transition occurred in the physical baseline.

### Paired-run acceptance and evidence limits

After both users finish normal Keychain approval and both installed executable
hashes match, start a bounded synchronization-only unified-log capture on each
Mac. Use `log stream --style ndjson --level default --timeout 720` with predicate
`subsystem == "in.werai.audio.dev" AND category == "synchronization" AND (eventMessage BEGINSWITH "Dev timing sample" OR eventMessage BEGINSWITH "Dev timing unavailable" OR eventMessage BEGINSWITH "Playback timing")`.
Keep output and stderr in a private temporary directory, retain dropped-log
notices, and poll the running capture handle rather than blocking the agent for
720 seconds. This collects numeric diagnostics, not microphone/screen/audio.

- Record an agreed UTC START independently, without track titles. The recording
  must contain a full 60-second startup and 600-second uninterrupted playback
  after START; the extra minute is arming time, not playback evidence.
- Startup must establish advancing sample time, increasing measured counters,
  and fresh finite drift. Record time to first measurement and the final 30
  seconds of startup; do not erase initial unavailable observations.
- During uninterrupted playback, require observations from both devices without
  unexplained log gaps longer than three seconds, observation/drift ages no more
  than 500 ms, peer reports no more than 2.5 seconds old, and software drift below
  40 ms. Record new late/resync/drop events and any route/pause changes. These
  prevent a clean-run verdict even if the final snapshot recovers.
- Report sampled p50/p95/max and unavailable duration. Missing/stale evidence,
  dropped logs, or elevated RTT (40 ms or more) is inconclusive, not an acoustic
  pass. One-second samples cannot rule out every between-poll transient.
- Use a separate 180-second capture for leave/rejoin: 30 seconds stable, receiver
  leaves for 15 seconds, then rejoins. The test target is fresh advancing timing
  within 60 seconds of rejoin and another 30 seconds stable; this is an acceptance
  target, not a product guarantee. Compare counters within their own player
  sessions, never subtract across resets.

The installed `6f` candidate's numeric reports do not expose actual varispeed rate or signed controller
phase error. They demonstrate repeated estimator acceptance and report freshness,
not that a non-unit correction was applied or neutralized when needed. Separate
physical listening/acoustic evidence is necessary for alignment; low RTT and
small inferred residual cannot exclude asymmetric clock-offset error.

The follow-up source now records signed controller phase only for a valid current
estimate and the actual audio-unit playback rate after that poll's correction or
missing-clock neutralization. These are local observation fields, not new wire
fields or acoustic measurements. Missing phase is explicit; measured-and-realigned
polls retain their distinct reason. An actual offline production-player test checks
reported versus applied rate on every poll, including the 1.01-to-1.0 transition.
This supersedes the missing-fields limitation for the new source, not for the
already installed candidate or prior logs.

Review follow-ups passed regression-first: `future-reporting-red.log` reproduced
10 runtime assertions; `future-reporting-green.log` passed 68 tests after fixing
single-track host/wire snapshots, all explicit stop continuity resets, and both
rejected-latency allowance paths. `applied-rate-telemetry-green.log` then passed
69 tests in 11 suites, including the new rate/phase telemetry checks and combined
clock simulations. Invalid explicit future budgets remain fail-closed rather
than being silently clamped. No playback correction formula, wire schema, native
layout, identity data, or installed app was changed by this follow-up. Paired
playback and Bluetooth validation remain pending.

A native Logger probe also reproduced truncation of the old whole-detail dynamic
log value near 1 KB, so previous line tails cannot establish absent rate/counter
values. Dev timing samples now use UTF-8-safe numbered chunks: 640-byte payloads,
under 800 bytes including monotonic time, a per-snapshot UUID and `part=index/count`
framing. Production transition logs now use the same bounded framing while
remaining transition-only; dev logs remain per-sample. The earlier exact-helper native
probe preserved all 49 messages for numeric and Unicode payloads (maximum 704
bytes per line): `/tmp/alo-log-limit.278o5f/chunks-stream.ndjson`.
Capture consumers must group parts by Mac/process and snapshot UUID and
require exactly every index before interpreting the reassembled sample; missing,
duplicate, or mixed-snapshot parts invalidate that sample rather than imply a
missing field. Verify identical kind, monotonic time and count across the parts.
The UUID separates independently collected snapshots even when their timestamps
coincide. Retain the original parts with the reconstructed evidence.
The final `dev-timing-chunks-green.log` run passed 71 tests in 12 suites,
including Unicode sizing/reassembly and incomplete-capture rejection.

The future-render allowance has speaker-route evidence only. Neither the inspected
CoreAudio nor AVAudioNode contract establishes that every Bluetooth route's future
host lead excludes device/transport latency. Bluetooth validation must measure
the actual route's buffer, rate, safety, presentation latency, future-host lead
distribution and gate counts during startup, steady playback and route changes,
then perform the paired playback/listening test. Do not claim all earphones fixed
from a Mac-speaker production-player test.

### Live choppy-audio incident — 2026-09-07

The longer paired capture failed; the earlier steady interval is not a completed
sync pass. The numeric analyzer flagged the incident before the user's choppy-audio
report. Preserve `/tmp/alo-paired-sync-6f.thDvOO/raj-stream.ndjson` and
`/tmp/alo-live-incident.mnK6rb/raj-stream.ndjson`. Times below are UTC:

- 17:46:25.883: local timing snapshot exceeded its 2.5-second timeout;
  17:46:29.204: its result was rejected as late.
- 17:46:30.252: first observed increase to 22 late packets / 1 resync, after
  an 8.066-second gap between monotonic timing samples. Subsequent 2.6–4.7-second
  gaps accompanied further counter bursts.
- 17:47:58.800: 1270 late / 28 resyncs despite a small fresh render residual.
  A small post-recovery residual does not establish uninterrupted audio.
- 17:48:59: only the agent-owned test build was cancelled: swift-test PID 54747,
  driver 54829, frontend 54834. It began about 17:45:16 and was still compiling
  tests with `-num-threads 14`; no tests from that retry had begun. The frontend's
  instantaneous CPU readings were 8.3% at 17:48:18 and 17.3% immediately before
  cancellation. This was controlled removal of a load confound, not an audio fix.
- 17:49:16.264: another increase to 1484 late / 34 resyncs; those counters then
  remained unchanged through at least 17:50:18. Temporal improvement does not
  prove build load was the root cause. Installed Dev PID 29346 was not changed.

The actual-process stack at 17:48:38.615 is stronger evidence of the immediate
blocking mechanism: `/tmp/alo-live-incident.mnK6rb/raj-process-stack.txt` shows
38 sampled stacks in `scheduleBuffer → GetAttachAndEngineLock → sleep` and
26 in `lastRenderTime → GetAttachAndEngineLock → sleep` on the serial secure
playback queue (lines 975–1020). Another 98 stacks traverse AVAudioPlayerNode
buffer-command destruction and output/device-latency queries (lines 652 onward).
These are stack sample counts, not independently measured delay durations. They
establish engine-lock contention during this incident, not its initiating cause
or proof that delayed completion accounting alone caused every lost deadline.

Next regression work holds real playback completion delivery deterministically
to test bounded scheduling/accounting. Its default-nil injection must preserve
production behavior. No new builds are allowed during the active capture; resume
only after coordination, with bounded `-j 2` rather than another 14-thread build.
The four review fixes remain uncommitted/unverified: logging RED reproduced three
runtime assertions; the first GREEN attempt hit an offline fixture precondition;
the corrected-fixture retry was cancelled before testing. Do not label it GREEN
or push these fixes until the resumed checks pass. UI work remains deferred.

### Native content-timeline regressions and pending fixes

The actual production-player offline regression reproduced expired concealment:
no-gap marker 1 ms; 200 missing packets produced a 1001 ms marker delay while
late/resync counters remained zero. The useful RED log is
`/tmp/alo-underrun-probe.5kSv5c/production-concealment-zero-tolerance.log`;
earlier attempts that missed their arrival deadline were fixture failures, not RED.
The fix tracks scheduled source-frame/capture ends, reanchors expired or ambiguous
missing ranges, bounds silence work to ten packets per drain, checks capacity
per silence and removes recursive backfill. It preserves timely one-packet loss
and modular sequence ordering. This changes neither callback type nor queue size.

The low-priority single-thread run
`/tmp/alo-underrun-probe.5kSv5c/concealment-nice-single-thread.log` verified the
expired fix with 0/1/200 gaps at normal and wrapping sequences, including a fresh
real marker after intentional reanchoring. The four prior review fixes also
passed their controls. The entire run was NOT green: 50 of 51 tests passed;
the separate contiguous-packet case meaningfully failed with 61 ms content delay,
arrival below the old 100 ms threshold, and zero late/resync counts.

A source-relative native sample-position precheck is now being added for that
contiguous case. It must be verified with a fresh-packet recovery oracle. It is
not an atomic guarantee against an engine-lock wait during the subsequent
schedule call; a separate real-native test will exercise that check/enqueue race
before any post-check or scheduling change is accepted. None of these offline
markers is an acoustic measurement, and no full sync pass or installation follows
from these intermediate results. See `docs/sync-incident-2026-09-07.md` for the
continuing real-device incident, including direct concealment/engine-lock stacks.

The subsequent `enqueue-race-mutation-red-2.log` run established two more real
failures: changing target delay, clock offset, or measured output latency bypassed
the near-deadline guard despite a passed native source position; and an injected
60–65 ms admission/enqueue delay shifted actual native markers by about 58.5 ms
at rates 0.99/1/1.01 while all three no-delay controls remained about 1 ms. The
injection advances the real offline engine but is not an engine-lock reproduction.
The same run caught a new boundary regression: equality with the next source
frame is valid. The guard must use strictly greater, with exact-equality and
one-frame-past controls, rather than treating equality as an underrun.

Verified targeted coverage now includes an unconditional valid native source-position
precheck (mutable deadlines cannot waive it) and a conservative post-enqueue
check: the entire admission-through-enqueue interval must exceed one packet
duration AND native position must be past the entire admitted packet window.
This avoids resetting merely because normal audio starts playing during a call.
It is not an atomic placement proof, does not cover every sub-packet race, and
does not fix the separate initial-start scheduling race. No queue sizes or
completion callback types have been changed.

The final `content-recovery-green.log` run passed all 54 tests in 10 suites
(192.74 s single-thread, nice-19 build; 8.211 s tests). The earlier
`content-continuity-green.log` was not fully green: four 9/10-loss normal/wrap
cases exposed repeated application of the first-missing-frame admission window.
Admission is now once per contiguous gap within one drain, reset on a real packet
or new drain. Every silence still checks native position, expiry, exact source
frames, capacity and the shared ten-packet work limit.

Actual offline PCM controls now preserve 1/9/10 missing packets as 5/45/50 ms
silence plus approximately 1 ms graph delay, with no resync, including sequence
wrap. Both 200-packet expired cases recover explicitly and render a newly
received packet approximately 1 ms after the fresh reference; they do not replay
the old one-second backfill. Contiguous one-frame/60-ms underruns and mutable
target/offset/output-timing cases trigger recovery before fresh content. Injected
enqueue-delay cases at rates 0.99/1/1.01 recover and render fresh markers within
1–1.625 ms of the new reference; their no-delay controls remain approximately
1 ms from the original source reference. These are offline marker measurements,
not paired acoustic alignment, and the reference intentionally changes on reset.

Local observation details now include bounded, saturating recovery counts and the
last reason: concealment discontinuity, passed native source position, or passed
enqueue window. Actual production-path tests assert these distinct counts;
missing observations explicitly report recovery telemetry unavailable. No wire
fields, completion callback policy or UI layout changed. Source remains uninstalled
pending review and real-device validation; green offline tests do not establish
that the user's live crackling or every possible underrun is fixed.

### Review of candidate 67c255b: admission continuity and deterministic fixtures

`admission-all-guards-red.log` reproduced eight runtime assertions: active clock
conversion failure, buffer-allocation failure and audible-time overflow retained
the old source mapping and failed fresh native marker recovery; a 4096-frame
output fixture deferred concealment at 75 ms lead despite approximately 96 ms
measured scheduling headroom. Allocation failure uses a default-nil internal
test seam; decoded packet validation and overflow prerequisites remain asserted.

`controlled-admission-red.log` retained those failures and reproduced the same
mapping loss for a stale packet containing unqueued source frames. The scoped
fix retires active mapping on the three admission failures and on stale packet
tails extending beyond the checked queued source end. Fully covered stale
duplicates remain ignored. Concealment now reserves the larger of 50 ms and
measured scheduling headroom. Recovery details distinguish admission drops from
passed native source position; expired native intervals no longer increment the
generic concealment counter.

CI on 67c255b missed wall-clock fixture wake prerequisites under load. The native
offline tests now inject a controlled scheduling clock; production defaults to
the real monotonic clock, and native sample positions and PCM remain actual
AVAudioEngine output. No live/network timing test was converted. Independent
clock-only and native-only advancement controls pin the post-enqueue AND gate;
the latter is a synthetic branch control, not a claim that physical underrun
occurs in zero elapsed time.

Removing wall waits exposed a near-future native scheduling quantum in the
already-empty timely-loss fixture. Timely cases now accept two real seed packets
and retain one known queued packet after rendering the first. Their exact oracle
includes those 240 known frames, missing-frame silence, and the original bounded
graph delay. The original 200-packet empty-queue recovery and contiguous boundary
oracles remain unchanged. The first combined run passed every actual PCM/control
case; its sole failure was an old formatter literal omitting the new counter,
not an audio failure. The final `review-admission-green-2.log` run passed all
57 tests in 11 suites (single-thread, nice-19 build; 0.087 s test execution).
This includes the precise new recovery-count formatter, native fresh-marker
recovery for each rejected admission, stale-overlap/covered-duplicate controls,
large-headroom concealment, and the unchanged expired-content oracles.

Separate bounded audit still required: the late-packet comparison adds 100 ms to
an unsigned desired render time without checking overflow. Near-maximum timestamp
reachability was identified by arithmetic inspection, not yet an isolated runtime
RED; this pass deliberately does not claim to fix or test that separate path.
No paired acoustic or live crackling success follows from these offline results.

### Empty native boundary follow-up after c92

The c92 full-CI empty-boundary marker failure must not be dismissed as a timer
fixture failure. A standalone native AVAudioEngine offline-output probe at
`/tmp/alo-native-boundary.sd57OG/results.log` ran 48 native cases: after consuming
exactly source frame 240 with no queued prefix, nil scheduling produced marker
528 versus source 240 in all twelve runs; explicit scheduling at the consumed
sample 240 produced no marker within 100 ms. With a known queued 240-frame prefix,
both scheduling modes produced marker 528 versus source 480 in all twelve runs
each. Explicit scheduling at an expired target is therefore not a drop-in fix.

The wrapper contract now treats reaching the next source boundary as uncertain
continuity, while preserving strictly positive queued lead. The runtime
`wrapper-boundary-red-2.log` reproduced eight missing-retirement/count assertions
at exact equality across timing mutations; its queued-prefix control passed the
exact 480...576-frame marker oracle with no reset. Two allocation-attribution
assertions and one cause-neutral label assertion also failed as intended. The
earlier `wrapper-boundary-red.log` was canceled before tests at approximately
20:20:47 UTC during live capture, and is not RED evidence.

The narrow fix uses reached (`>=`) for admission and concealment only. The
post-enqueue whole-packet-end comparison remains strict (`>`), with its original
elapsed-time AND gate. Recovery fixtures render the first newly queued packet
when it was accepted after retirement; only a dropped first packet requires a
fresh successor. This avoids introducing a second, artificial capture-timeline
discontinuity in the test. Generic concealment refusal is named
`concealment-unavailable`, while failed silence allocation records
`content-admission-dropped`. The final `wrapper-boundary-green.log` run passed
all 59 tests in 11 suites, including the prior 57-test coverage, new exact-prefix
control, boundary retirement and both diagnostic regressions. Tests took 0.721 s
after the single-thread nice-19 build. Every boundary recovery rendered the real
marker at frame 48 relative to its new anchor; queued-prefix control retained
marker 528 relative to source 480 without a reset. This is a targeted native
offline result, not a clean full-CI run or successful paired acoustic test.

This addition covers exact equality only; the previous strict comparison already
retired positions beyond the boundary. Equality occurs frequently in the
240-frame offline fixture, but its frequency in production depends on the route,
native render cadence and playback rate. No universal IO-quantum or acoustic
coverage claim follows from this test.

The external review of 8b093f0 completed with CodeRabbit clean and Claude
follow-ups. Its proposed holdover-fixture regression was not reproduced in one
unchanged run of both 20/100 ms cases (`holdover-reproduction.log`): rate returned
to 1, resync stayed zero, and strict assertions passed. This is not proof that
every scheduler cadence is safe; the fixture was not changed without runtime RED.
The actual incompatible-frame-gap refusal test passed before any production
change, confirming `concealmentUnavailable` dispatch and fresh PCM recovery.
The operator-facing `native-source-position-reached` label was regression-tested
against the prior `passed` text, and all three comparison call sites now specify
their strictness explicitly. Allocation/refusal test messages distinguish queued
prefix playback from newly anchored recovery. A separate silence-allocation
counter was rejected as optional granularity: generated silence is still
admitted content and the generic admission-failure cause is deliberately neutral.
The `continuity-boundary-combined-green.log` run passed 59 tests in 10 suites,
including all requested boundary/label/refusal cases and the separately owned
health-diagnostic changes. The known sustained-enqueue-cost RED was explicitly
excluded; this targeted result is not a claim that the entire project or live
playback is green.

### Deferred native-window implementation notes

Deployment update: Raj completed normal Keychain approval; the installed `6f`
Dev process is responsive in Main with Shyam visible and paused. No playback
controls were changed for this inspection. Finder Get Info showed the installed
Dev icon with a clean rounded preview and no opaque square/fringe; canonical
asset verification and signature checks also passed. This resolves the earlier
local startup blocker, not the still-pending paired playback validation.

Read-only inspection confirms the screenshot's custom chrome is still in the
current source; it is not a stale screenshot. `ALOAppDelegate` hides native
traffic-light buttons and the title, makes the setup window transparent, and
uses a fixed 800-by-640 idle size. `MacNetworkSetupView` adds a second ALO/Networks
header with custom close/recovery buttons, a 24-point rounded material clip and
10-point outer inset. Its sidebar is a native sidebar List inside a plain HStack,
not a native split-view window, with another material surface. This combination
must be addressed at the window and container boundaries, not by recoloring rows.

After paired sync validation, scope the replacement to the identity-ready
Networks browser: native title/toolbar and traffic lights, an edge-aligned native
split-view sidebar/detail, compact resizable initial dimensions, and a quieter
empty state. Preserve the accepted identity onboarding and existing import,
approval, members, identity-export and channel actions. Verify transitions between
onboarding, browser, joining, failure and live playback, including reopen with a
pending approval and a minimum-size/long-label render. No UI layout changes were
made during this inspection; sync remains the prerequisite.

### Bounded native PCM coalescing (validation in progress)

The sustained enqueue-cost native PCM regression motivates a bounded four-packet,
960-frame cohort after the immediate startup packet. Each packet still passes
source/capture validation and DSP separately. Held PCM counts as pending original
packets; one unique native completion ticket carries its original packet weight,
and duplicate or retired-generation callbacks cannot release another ticket.
The callback remains `.dataPlayedBack`, including audible predecessor retirement.

Secure receiver and host declare their existing 20 ms and 5 ms maintenance
cadences from the same constants as their timers. Real maintenance anticipates
the next poll and flushes partial tails even after the source stops sending.
The legacy 50 ms path explicitly disables holding; its timer is unchanged.
Fresh flush time is read after possibly blocking native work. Headroom determines
when holding must end; already-active positive-deadline PCM may be submitted
immediately inside that headroom, while startup retains its stricter gate.
Nonpositive deadlines and reached source positions retire the mapping. The
post-enqueue elapsed window starts at actual flush admission, excluding deliberate
holding, and retains the strict whole-buffer-end native check.

Accepted per-packet timestamp jitter does not stretch the merged PCM duration:
the cohort end deadline is its first deadline plus total source-frame duration.
Native offline fixtures flush through actual maintenance before replacing a
known startup prefix or asserting a held tail's result; they verify zero held
packets and exact original-packet credits before prefix replacement. Their PCM
marker tolerances are unchanged. These are controlled native-output tests, not
proof of acoustic alignment, actual engine-lock latency, or a clean paired run.

The first combined build exposed a separate runtime safety failure before the
native batching oracles: offline startup returned a nonnil `AVAudioTime` with
both validity flags false, and `maintainSync` passed it to native player-time
conversion, which raised an uncaught AVFoundation exception. Preserved logs:
`/tmp/alo-sustained-enqueue.eROFtT/cohort-combined-first.log` and isolated native
runs alongside it. Conversion now checks for at least one valid clock flag;
invalid clocks remain unavailable. This timestamp shape was observed in the
offline tests, not the installed live app, and is not an established cause of
the reported live audio interruptions. The pure cohort checks passed separately;
the health suite produced its 11 expected review-regression assertions.

Combined follow-up validation passed 69 tests in 15 suites (293.74 s build,
2.338 s runtime), including the native batching workload, prior boundary/loss/
enqueue-race controls, clock validity, tail retirement and health regressions.
Log: `/tmp/alo-sustained-enqueue.eROFtT/cohort-combined-second.log`.
With the unchanged simulated 7.5 ms per-enqueue cost, production submitted 160
packets in 40 native calls, matching the reference's marker at frame 12048,
38520 rendered frames and zero recovery; the old unbatched runtime RED remains
preserved. Exact known-prefix and fresh-recovery marker bounds were not widened.
This does not cover every native contention pattern or prove live acoustic sync;
external review, CI and paired playback remain required before a release claim.

### Voice route completion investigation

The receiver's voice path already uses `.dataRendered`; the media callback-cost
finding is not automatically its cause. A separate native offline regression
held four real completion callbacks across the existing configuration-change
notification/reconnect path, queued 1920 new frames on the same voice session,
then released the old callbacks. Those callbacks reduced new-route credits to
zero (sole issue in 37 tests, log `/tmp/alo-f1-live.7jWPES/policy-green-voice-red.log`).
This is an accounting RED, not proof that a physical route switch caused the
reported low/choppy speech. The scoped fix fences callbacks by immutable session
identity and route generation, rotated before stop/reset; a control also releases
new-generation real callbacks and checks that they still spend their own credits.

Voice telemetry is numeric local playback evidence: admitted audio/concealment
counts, capacity drops, route resets, maximum playback-queue arrival gap, queued
frames, participant gain and last actual-audio pre/post-leveler RMS/peak. It emits
at most one small line per second per player on activity. With simultaneous
speakers this is sampled-session evidence, not complete per-session coverage.
Concealment never overwrites the last actual-audio level with synthetic zero.
No PCM, names or device identifiers are logged; no gain or AEC behavior changed.

Voice follow-up verification passed the real callback regression, current-route
completion control, telemetry tests and existing WalkieTalkieAudio tests. The
combined 42-test batch had only four intentionally introduced timing-policy RED
assertions; voice had none (`/tmp/alo-voice-route-red.dKN5y2/voice-green-policy-red.log`).
There were no new Session/Sendable warnings. A separate single zero-PCM real-output
600 ms startup probe passed: 598.75 ms lead, 26 pre-start polls with valid negative
sample positions, zero resync, then advancing positive sample time; maximum poll
gap 18.671 ms. Log: `/tmp/alo-future-start.5ttuFH/hardware-startup.log`. That probe
does not measure acoustic alignment, microphone capture or two-device voice.

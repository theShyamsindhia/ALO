# Audible desync with healthy render-clock diagnostics

## Observed behavior

Two Macs ran the same development build (`6f7d33c`), with Spotify broadcast
from one Mac and playback on the other's built-in speakers at 48 kHz. The
listener reported roughly a one-second echo, followed by worsening desync and
broken audio. Neither a small network RTT nor a small render-clock residual
established that the two devices were playing the same content position.

Times below are UTC on 2026-09-07:

- At 17:46, receiver timing snapshots stalled and its late/resync counters
  began increasing. The uninterrupted observation interval failed.
- One receiver-only **Sync this Mac** action occurred around 17:58:21. This
  was not an app restart or a rebroadcast. Audible recovery was not confirmed.
- At approximately 18:21 and 18:24, the listener again reported audible
  desync, then worsening audio breakup. Receiver counters remained at 1508 late
  packets and 35 resyncs; current render drift was approximately 0–0.5 ms.
- The preceding ten-minute receiver capture contained 596 samples with no
  counter changes, RTT 3.8–4.2 ms, and a maximum snapshot interval of 1.059 s.
  The maximum reported render drift was 16 ms. These observations did **not**
  contradict the audible failure: they measure a different property.
- A sender-side report covering 18:14–18:24 showed its own counters at 20 late
  packets and two resyncs, increased from an earlier 0/1 baseline. The onset
  and its relationship to the receiver's audible offset still require correlation.
  Subsequent sender log inspection placed the transition at 18:12:29, following
  an unavailable snapshot and a stale snapshot, with the same app process.
- The user reported strong receiver crackling around 18:29. Our test build was
  cancelled at 18:29:45, then another receiver-only **Sync this Mac** action
  reset the receiver at approximately 18:29:57 (first observed counters 1534/36).
  The user explicitly confirmed the crackling was gone afterward. This confirms
  audible recovery after the intervention, not permanent recovery or echo
  resolution. Because compilation was also stopped shortly beforehand, this is
  not a single-variable causal test of the reset alone.

## Reproduced defect

`ExpiredConcealmentTests` exercises the production `SynchronizedPlayer` and
native AVAudioEngine in offline rendering mode. The test renders an empty
player queue for 48,000 frames, then delivers a timely successor after 200
missing 240-frame packets. Source frame indices and capture timestamps remain
aligned. The old concealment path enqueues the missing second as silence even
though the native output has already rendered that interval as silence.

The valid RED run produced:

| Case | Marker delay after append | Late packets | Resyncs |
| --- | ---: | ---: | ---: |
| No missing packets | 1 ms | 0 | 0 |
| 200 missing packets after native underrun | 1001 ms | 0 | 0 |

The marker is actual rendered PCM, not a calculated render-clock estimate.
The fixture explicitly checks native sample-time advancement, timely arrival,
sequence admission, and absence of the separate late-packet/reset path.
Earlier runs that missed the fixture's deadline were **not** valid reproductions;
zero-tolerance timer scheduling allowed the fixture to reach the intended path.

Offline rendering does not provide valid host timestamps or acoustic output.
This test proves the production backfill defect, not that every live incident
has the same cause. An adjacent contiguous-packet underrun requires its own
regression rather than being assumed covered by a missing-packet test.

## Live evidence and limitations

A three-second process sample around 18:24 observed 15 sampled stacks in
`concealMissingPacketIfNeeded` → buffer scheduling → audio-engine lock waiting,
and 35 sampled stacks in maintenance → `lastRenderTime` → the same lock wait.
It also observed native buffer-command destruction querying device latency.
These are sample counts, not measured operation durations. They establish that
concealment and lock contention occurred during the reported failure, but do
not reveal the precise expired interval or prove a completion-callback policy
is its cause.

## Regression and release requirements

- Never equate `AVAudioPlayerNode.isPlaying` or an advancing sample clock with
  continuous queued content. A player clock can advance through an underrun.
- A pre-enqueue timing check is not atomic with native scheduling. Engine-lock
  waits can consume the remaining scheduling window; a fix must test that
  interval rather than assuming scheduling returns immediately.
- Never backfill expired silence into an already-running content timeline.
  Recovery must preserve or explicitly reset the content-to-clock mapping.
- Bound concealment work and native queue usage, including recursive/repeated
  work performed inside a single admission call.
- Test timely loss, long gaps, partial frames, sequence wrap, ambiguous/huge
  gaps, and fresh playback after recovery. Test contiguous arrivals after an
  underrun separately.
- Keep marker-PCM tests alongside deterministic policy tests. A policy-only
  test cannot establish what the native renderer actually outputs.
- Capture analysis must fail or report inconclusive evidence for gaps, stale
  reports, unavailable snapshots, malformed telemetry, or counter increases.
  Even a clean software-only capture must not claim acoustic alignment.
- Validate the repaired build on both physical Macs during uninterrupted
  playback and recovery flows before claiming the live issue fixed.

## Follow-up verification

At approximately 18:37 UTC, the expired-concealment repair passed native PCM
cases with 0, 1, and 200 missing packets, each with ordinary and wrapping packet
sequences. The long-gap case reset the expired mapping once and rendered a fresh
production-scheduled marker 1 ms after append. The timely single-loss case
retained its timeline and rendered exactly one packet of replacement silence
plus the graph's observed 1 ms delay (6 ms total).

A separate `ContiguousUnderrunTests` regression then reproduced the adjacent
defect with **no missing sequence numbers**. A packet arrived 61.19 ms late,
below the existing 100 ms reset threshold, after 2,880 native underrun frames.
Its marker was displaced by 61 ms rather than the control's 1 ms, with zero
late packets and zero resyncs. The sole failure in the 51-test batch was this
intentional regression. The continuity repair therefore remained incomplete.

The subsequent combined run passed **54 tests in 10 suites**. It includes the
ordinary/equality boundary, one-frame-past boundary, target/offset/output-latency
mutations, 1/9/10/200-packet losses with sequence wrap, and a real-time scheduling
stall combined with native offline advancement at rates 0.99, 1, and 1.01.
Timely loss retained exactly the intended silence (6/46/51 ms including the
observed 1 ms graph delay). Stalled cases explicitly reset and recovered with
fresh production-scheduled PCM; recovery-relative marker delays were 1–1.625 ms.
The final run also verifies distinct diagnostic recovery counters.

At 19:13 UTC the user reported a subtle echo on the still-installed original
build, better than the earlier crackling but not as aligned as immediately after
forced sync. Counters were still 1534/36 and reported drift approximately 0.4 ms.
That is a new audible observation, not evidence that the uninstalled repair
failed or succeeded. A separate pre-install capture was preserved.

These results are offline native-render evidence. No repaired build had yet
been installed or released for this incident; two-Mac validation was pending.

### Candidate review and CI follow-up

Candidate `67c255b` was committed, pushed, packaged and shared for checksum
verification, but installation was explicitly held. CodeRabbit reported no
findings; Claude identified active packet-admission failures retaining an invalid
content mapping and a concealment admission window shorter than the scheduling
lead of large-buffer output devices. Those require separate regression coverage
and disposition before installation.

CI run `34155255083` passed both app builds, but the full Mac run failed with
22 issues across the three new native-offline suites (1,148 tests / 185 suites
executed). Every issue was a fixture arrival/deadline prerequisite: the runner
woke after the intended admission window. These are not valid reproduction of
the PCM defect, nor a passing CI result. The existing strict live-timing tests
passed. The follow-up is to control the offline fixtures' monotonic clock while
retaining actual native PCM rendering, native sample advancement, and unchanged
marker assertions—not to relax live thresholds, skip tests, or retry until green.

Shyam's sender also recorded a second timing stall overlapping the subtle-echo
capture: late20/resync2 at 19:13:42.130154 UTC, a snapshot timeout and stale result,
then late40/resync3 at 19:13:49.998276 UTC. The valid samples' monotonic timestamps
advanced 7.868 seconds in the same process. Historical log export warned of a
wall-clock adjustment; that warning does not prove an adjustment caused the
stall. Preserve monotonic evidence and avoid treating cross-device wall times as
precise physical alignment measurements.

### Remaining small-offset measurement limits

The player's current phase estimate compensates `outputNode.presentationLatency`,
the device/stream term. Native graph characterization separately observes about
1 ms of pipeline delay, with rate-conversion effects requiring their own checks.
Equal graph delay on both Macs largely cancels in a relative comparison; this
does not establish the cause of the reported subtle echo. Current telemetry does
not independently observe content correspondence or acoustic alignment.

A further latency change requires a production-player native impulse regression
at 48/44.1 kHz and rates 0.99/1/1.01, separating constant phase bias from accumulating
interval error. Do not simply add downstream latency queries to the live polling
loop: the incident stack already observed native latency-related IPC waiting.
Any additional hardware/graph measurement must be bounded and separately assessed
for interference with playback.

At approximately 19:47 UTC, before installing any replacement, the user again
reported a **large delay without crackling**. The receiver's preceding five
minutes contained 298 samples, maximum monotonic sample gap 1.024 seconds,
unchanged late1534/resync36, and approximately 0.5 ms reported phase error.
A new three-second stack sample again observed native buffer-command completion
querying output presentation latency/CoreAudio, and maintenance waiting on the
engine lock. These observations motivate a bounded silent-output callback-mode
comparison; sample counts alone do not establish callback latency or causality.
Do not swap completion types based only on those stacks: queue accounting also
participates in audible predecessor retirement, so rendered and played-back
completion semantics are not interchangeable.

The matching sender history later showed 601 samples from 19:42:00–19:52:10 UTC
in PID841: own late94/resync8 initially, late115/resync9 at 19:48:26.067439,
resync10 at 19:48:31.098907, and resync11 at 19:51:30.821737. Two stale-snapshot
warnings preceded the first transition. The reported maximum valid-sample wall
gap was 4.325 seconds; retain the earlier wall-clock caveat. Listener reports
remained resync36/drift0.5ms. This establishes repeated sender timing disruption
during the audible incident, not its exact acoustic cause. The remote history
was preserved; a new remote live capture was not started.

### Silent live-output callback comparison

A separate native-engine ABBA probe compared `.dataPlayedBack` and
`.dataRendered` while the installed app and existing activity remained running.
This was **live default-device output with all-zero PCM**, not offline rendering,
microphone capture, or an acoustic alignment measurement. It used 48 kHz stereo,
rate 1, 250 ms initial queued audio, 5 ms arrivals and the same 140-buffer cap.
Each approximately 12-second run comprised 2 seconds warmup, 8 seconds measurement
and 2 seconds drain, with a three-second stack sample at the same point.

Verified artifacts: `/tmp/alo-callback-abba.BZEN5z/RESULTS.md`, `run-5-played.log`,
`run-6-rendered.log`, `run-7-rendered.log`, `run-8-played.log`, and matching stacks.
All four runs exited successfully and drained their outstanding completions
before stop. An earlier run with failed JSON serialization was excluded; the
complete ABBA sequence was rerun after fixing only summary serialization.

| Mode / run | scheduleBuffer p95 | maximum | CPU time over ~12 s | cap drops |
| --- | ---: | ---: | ---: | ---: |
| Played-back / 5 | 6.281 ms | 23.105 ms | 0.775 s | 0 |
| Rendered / 6 | 0.033 ms | 2.463 ms | 0.278 s | 0 |
| Rendered / 7 | 0.030 ms | 2.969 ms | 0.270 s | 0 |
| Played-back / 8 | 6.278 ms | 13.256 ms | 0.761 s | 0 |

Played-back stacks contained 62/46 samples under output-presentation-latency
queries and 75/66 under the engine lock; neither named hotspot appeared in the
rendered stacks. Stack counts are not durations; the table separately measures
the native schedule call. Zero cap drops does not establish that all timer
deadlines were met. Callback elapsed time includes intentionally queued PCM and
must not be treated as an audio-quality score.

This supports callback-mode-dependent native property/lock churn on this route,
not a complete causal explanation of the user's delay. The extra silent engine
and sampling are observer interference. No route, volume, capture, installed-app
or production callback changes were made for the probe. Rendered completion is
not semantically equivalent to played-back completion: existing accounting also
protects audible predecessor retirement. A direct callback swap would therefore
need a separate retirement contract and tests. Coalescing several small buffers
is a possible way to reduce per-buffer work, but requires regression tests first
for exact source-frame mapping, bounded latency/capacity, loss, reset, rate and
cutover/retirement behavior, followed by real-device measurements.

### Local c92 development checkpoint

The local c92 candidate was installed with executable SHA-256
`c36a4aefb2548ee4b86d6a74ab09708f3b72aeefb7e79ce0854f84d37b952642` and
launched as PID 1978. At this checkpoint it was awaiting the user's normal
Keychain approval; this is not a successful paired-playback validation.
The previous app was retained at
`/Users/raj/Library/Application Support/ALO Dev Backups/backup.0zDaE7/ALO Dev.app`.
No callback-policy change is included in this deployment checkpoint.

CI run `34157629270` subsequently passed both app builds but failed two assertions
in 1,151 tests across 186 suites. The complete log is preserved at
`/tmp/alo-dev-candidate.IXAFvw/ci-failed.log`:

- Exact empty-queue control (`gapNanos=0`, target-delay mutation) rendered its
  marker at frame 1488, beyond the existing frame-1200 limit. Other empty-boundary
  controls rendered at 288, 528 and 1008; the actual underrun recovery cases
  rendered fresh markers at 48. Controlled admission time rules out the previous
  wake-overshoot prerequisite failure. Native nil-scheduling and empty-queue
  behavior require isolation before classifying this as fixture or production.
- Eight-client live bounded fan-out received a minimum 45 packets, below the
  required 50, with zero injected scheduler oversleep. This remains a failed live
  gate, not an automatically accepted runner artifact.

No tolerance was relaxed, no failing observation removed, and no release was
approved. The c92 deployment is a bounded development experiment only.
Apple's [player scheduling semantics](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)
distinguish appending to queued commands from scheduling on an already-playing
empty node; the latter has no exact immediate-start promise for `at: nil`.

A follow-up native-only offline probe isolated that distinction without ALO's
player wrapper or stop/reseed adapter. All 48 cases verified native sample 240:
12 empty-boundary nil enqueues produced a marker at 528 rather than the expected
240 plus 48 graph frames; 12 explicit sample-240 enqueues produced no marker
within 100 ms. With 240 frames genuinely still queued, both methods produced the
expected marker at 528 (source 480 plus 48) in all 24 cases. Evidence lives at
`/tmp/alo-native-boundary.sd57OG/results.log`. This establishes native empty-boundary
content displacement, not its contribution to the user's full acoustic delay.
Explicit scheduling at the consumed boundary is not a safe substitute. The next
wrapper regression must require retirement at an exhausted boundary and preserve
continuity with positive queued-frame lead, before changing the production guard.

### Paired c92 diagnostic run: 20:23–20:26 UTC

Both Macs installed the identical c92 signed executable above. Raj used PID1978;
Shyam reported PID47540, matching archive/executable hashes and strict signature
verification, production quit, old Dev backed up and identity/network data kept.
The original 660-second proposal was intentionally shortened to 180 seconds once
counter increments established failure. Neither device changed source, route,
volume or reset playback during that window. No compilation ran in the window;
an earlier local single-thread compile was canceled at approximately 20:20:47.

Raj reported intermittent blanking followed by periods of stability. The local
capture at `/tmp/alo-c92-live.JDTCVq/paired-live.ndjson` contains 179 complete
measured snapshots over 179.25 seconds. Maximum reported drift was 0.2 ms, render
sample age 24 ms, RTT 4 ms and sample gap 1.025 seconds. The existing checker
returned exit 2 for increasing late/resync counters, unverified telemetry and
insufficient standard observation duration. Small drift did not produce a pass.

Shyam's tagged coordination response reported 179 complete three-part sender
snapshots and no incomplete snapshots, all Broadcasting in PID47540, with maximum
gap 1.157185 seconds. Own late/resync/native-position counters rose from
239/11/9 at 20:23:00.022893 to 475/17/14 at 20:25:59.560143. Reported listener
resyncs rose from 100 to 154. The remote original startup/live files were retained;
this paragraph attributes their results to the remote agent, not a local raw-file
analysis. This is a failed paired diagnostic run, not acoustic validation or a
successful 660-second test. Post-20:26 local samples may include resumed compiler
load and are excluded from this assessment.

### Played-back callback coalescing experiment

The next fixed ABBA comparison retained `.dataPlayedBack` in both variants,
changing only grouping from one 5 ms packet to up to four packets per native
buffer. `/tmp/alo-callback-coalescing.XMkTct/RESULTS.md` and its original run logs
preserve the measurements. A shared no-engine accounting preflight passed 126
checks before native output ran. Those cover exact 1–3-packet tails, pending
credits, capacity, deadline equality and duplicate/out-of-order/stale callbacks.

All four approximately 12-second runs completed the prescribed workload without
retry: 2,001 input ticks plus 50 priming packets, 2,051 completed packet credits,
no cap drops and no pending/outstanding credits at stop. Single-packet runs used
2,051 native buffers and 1.120/0.845 CPU seconds; grouped runs used 514 buffers and
0.436/0.421 CPU seconds. Scheduling-call p95 was still 7.597/7.529 ms versus
6.938/6.845 ms, respectively. Mean CPU fell about 56% in this small comparison;
that is not proof the stalls or acoustic delay are eliminated.

This used zero PCM on the unchanged default output, with no microphone, route,
volume or installed-app changes. The CPU window includes priming; scheduling
latency is measured during seconds 2–10. Actual partial batches reflect priming,
source-end and deadline flushes and were not padded. Production adoption still
requires source/capture-ledger, recovery, capacity and cutover integration tests.
Maintenance cadence must be accounted for: merely checking a 20 ms age at a
20 ms polling interval can hold a partial batch much longer than 20 ms. A blocked
executor cannot provide a strict wall-clock flush guarantee.

### Sustained scheduling-cost regression and adoption contract

`SustainedEnqueueCostTests` reproduced queue exhaustion in the actual player,
not just a model: each enqueue consumed a synthetic 7.5 ms of controlled time
and 360 real offline-rendered frames while input packets represented 5 ms each.
Its verified 250 ms prefix exhausted after 100 costly enqueues and triggered a
recovery. The original incoming marker remained at frame 12,048, inside the
unchanged 12,000–12,096 prerequisite. An independent four-packet native reference
processed all 160 inputs without recovery under the identical cost. The recorded
RED is `/tmp/alo-native-boundary.sd57OG/continuity-invalidation-combined-red.log`.
The synthetic cost was motivated by measured scheduling latency; it does not
prove every real enqueue costs 7.5 ms or explain every physical desync.

Production coalescing must retain played-back completion semantics and weighted
packet credits, include held packets in the existing admission/retirement count,
and clear them on generation reset. The first packet remains immediate; later
contiguous cohorts are bounded to four packets/960 frames. Real maintenance must
flush partial tails even if no further source packets arrive, accounting for its
declared cadence and the first render deadline/headroom. Packet capture and DSP
validation cannot be skipped, and actual native source position must be checked
when flushing. Legacy 50 ms maintenance is outside this bounded batching contract
unless separately changed and validated. A native reference passing is not a
production fix passing; the actual-player regression must become green.

Raj subsequently described intermittent blanking followed by stabilization as
acceptable for now. This records a temporary user tolerance, not a clean paired
sync result, waiver of required CI, or permission to report acoustic alignment
from software clock measurements alone.

The implemented grouping passed the actual-player workload: 160 input packets,
40 native enqueues, marker frame 12,048, and no recovery, matching the native
reference without changing the 7.5 ms synthetic cost. The 69-test integration run
passed; the following full run passed 384 XCTest cases and reported one issue
among 1,174 Swift Testing tests: an old DSP fixture expected held packets to be
already native-enqueued. Its correction uses real maintenance and retains all
DSP-once/replay assertions, plus explicit held/native packet-credit checks.

Subsequent focused validation passed 52 tests, including 5 ms/20 ms maintenance,
disabled batching on unsupported cadences, the explicit 40-enqueue oracle, and
continuity regressions. Those regressions record recovery even without a drift
sample, preserve known incidents across missing telemetry subsets, and prevent a
known local interruption from becoming a passed verdict merely because its
receiver report disappears. Unknown telemetry remains distinct from a recent
reported interruption. The full suite and CI must be rerun for this final state;
none of these results replaces the next two-Mac physical validation.

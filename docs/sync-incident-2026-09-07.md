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

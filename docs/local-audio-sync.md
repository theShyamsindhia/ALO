# Local audio synchronization

## Reproduced clock failures and invariants

The uninterrupted-playback investigation reproduced application-queue clock
error. A 120 ms host processing interval entered the old three-timestamp estimate
as 60 ms of false offset. Changing load could therefore move receivers onto
different inferred clocks while media kept playing. A held annotation send also
proved that stamping before reliable output dequeue omitted real residence time.
Separate tests caught old probe reuse and anchors freshening stale clock evidence.
These reproductions do not prove every physical drift report has the same cause.

`ALOTiming.ClockSynchronizer` uses **t1 client send, t2 host receive, t3 host send,
t4 client receive**. Offset is the host midpoint minus the client midpoint; RTT is
`(t4-t1) - (t3-t2)`. See [RFC 5905](https://www.rfc-editor.org/rfc/rfc5905).
t2 is sampled before host work; t1 and t3 are stamped at their respective output
dequeues. A receiver reserves one coalesced FIFO probe item even under sustained
annotation traffic. It does not wait for the whole output queue to become idle,
and later traffic cannot overtake it. Same-executor sends do not add another
asynchronous hop. The 35-second busy-output regression must keep clock evidence
fresh, renew its lease, and deliver every injected audio packet.

Required boundaries:

1. Capture, network clock and audio hardware sample time are distinct. See
   [AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime)
   and [RFC 7273](https://www.rfc-editor.org/rfc/rfc7273).
2. Match live probe ID and exact echoed t1; never reset IDs on reacquisition.
   Reject impossible residence intervals and expired replies.
3. More than five seconds without observations, or a backwards local clock,
   discards the model. Four fresh samples are required to become ready.
4. Snapshot age means last successful observation, not new anchor/ticket time.
   Missing/stale references must never report verified drift or synced.
5. The estimator owns no sockets/UI. Production secure media uses the typed
   four-timestamp API, never the legacy ControlMessage adapter.
6. A receiver’s recovery must not reset other listeners or retime healthy peers.

`ClockSimulationTests` covers one-hour independent clocks, oscillator skew, jitter,
loss and changing host load. `ClockReacquisitionTests` covers gaps/reset/replay;
host/receiver session tests cover queued replies and anchor freshness. The real
TLS executor test checks timestamped sends. Strict live timing CI gates remain
required; simulations do not replace them.

These are application timestamps, not kernel wire timestamps. Asymmetric Wi-Fi/OS
delay and acoustic latency remain physical acceptance concerns. Test uninterrupted
two-device playback, Bluetooth changes, late joins and source/network interruptions.
Never claim audible perfection from a green simulation.

### Shared buffer negotiation

`SecureRoomTimingPolicy` separates network-delay votes from hardware output
floors. Once the initial listener cohort is established, later listeners cannot
repeatedly raise the entire channel's network allowance. Fresh hardware output
latency still applies to every synchronized output. During uninterrupted playback,
the shared delay never decreases; a genuine increase uses the existing bounded
future-cutover transaction, not a receiver-only delay or immediate global reset.

Capture can start before any other device joins. An empty cohort is therefore
not final: the first actual listener after the startup grace period establishes
it atomically when its report is accepted. This must happen before a concurrent
removal can interleave with the subsequent delay calculation. Once established,
removal or report expiry never reopens eligibility to unrelated later joiners.
Expired reports must be removed before every initial cohort freeze, including
both report acceptance and delay calculation; stale evidence cannot found it.
Keep the first-listener, record/remove/record,
`expiredUnfrozenGraceReportCannotExcludeFirstFreshListener`, and
`emptyPollingDoesNotExcludeFirstListener` regressions when changing this policy;
a permanently frozen empty cohort strands that listener on the default buffer
despite its measured recommendation.

Immediate first-listener founding after the capture grace period is intentional:
it favors stable shared timing over enrolling a second, nearly simultaneous
listener whose report arrives later. There is no new enrollment window after
the first report. Changing that tradeoff requires an explicit policy decision,
not reopening enrollment on expiry or removal. Founder departure does not lower
the shared delay while playback continues.

The delivery-gap test uses actual native offline PCM markers and a budget
selected by this production policy. Its synthetic 300 ms gap is a controlled
mechanism test, not a recorded network trace. Offline rendering cannot establish
hardware future-start behavior; real 600 ms startup and shared future cutover
still need native and two-device validation. See the incident record for current
results and limitations.

This contract applies to the secure media path used by current Network channels
(`NetworkAccountModel` creates them with `.secureV2`). The older `HostServer`
adapter still freezes its remote cohort when an identified local output first
plays; its intentionally empty cohort behavior has not been changed by this
fix. Do not copy that legacy rule into `SecureRoomTimingPolicy` or interpret
legacy fixture results as validation of current Network-channel negotiation.

## Receiver correction and diagnostics

Room settings → Automatically keep this Mac in sync is enabled by default and persists per Mac. A fresh measured error of at least 40 ms must persist for one second before hard realignment. Corrections have an eight-second cooldown; missing/stale samples and pauses clear accumulated evidence. Small errors continue to use the existing bounded ±1% playback-rate correction. This preference controls optional drift realignment, not mandatory recovery from a stopped render clock or changed audio device.

Updated receivers advertise ownership of this policy in their playback report. The updated host does not run its old competing lateness-triggered reset against these receivers. Legacy receivers retain their previous host fallback. Manual Sync this Mac still targets only the local receiver; no automatic room-wide reset is added. Each listener should enable their own local setting.

Settings → Audio timing separates measured network round-trip, the actual agreed room playback delay, hardware output latency and fresh local drift. Drift is unknown when no current measurement exists; it is not displayed as a fabricated zero. Game RTT appears separately inside the fighter. Low game latency is good; neither game nor audio resync makes a slow network faster.

A call can change the output route, sample rate or Bluetooth microphone profile, or stop the render clock. Existing AVAudioEngine configuration-change and watchdog recovery rebuild or realign playback. A call on one receiver should not require every listener to resync. A call that interrupts the broadcaster's source can affect everyone because their source itself has stopped or changed. This implementation does not detect or inspect phone calls, and does not guarantee recovery timing on untested hardware.

The earlier correction-policy change did not reproduce the user's rapid drift on their hardware. The overlapping receiver/host correction path was a concrete code risk fixed at that stage. Physical acceptance still requires AirPods/Bluetooth profile changes, wired devices, FaceTime/phone interruptions, sleep/wake, network loss and several Macs playing together. Automated policy tests establish thresholds, fresh-evidence requirements, cooldown and report compatibility; they do not establish audible call recovery quality. The subsequent live investigation below records newer physical failures rather than treating that earlier limitation as the current status.

## Native PCM admission and bounded grouping

The subsequent [September 7 live investigation](sync-incident-2026-09-07.md)
records audible delay and interruptions on two Dev Macs despite very small
reported drift. Native sample-position and content-marker tests are separate
from the clock estimator: a correct clock cannot repair PCM appended to an
already exhausted native queue.

The current coalescing implementation is under validation, not yet a physical
acceptance result. Its contract is:

- Enqueue the first packet immediately for its agreed playback target. Hold only later, source-contiguous,
  individually validated and DSP-processed PCM, up to four packets/960 frames.
- Flush partial tails through the real maintenance path even without new input.
  One cadence constant configures both each secure owner's timer and its hold
  budget. The legacy 50 ms owner disables holding. Executor stalls still prevent
  a strict wall-clock guarantee; this is not an extra playout delay setting.
- Use headroom to trigger an early flush, not to reject otherwise admissible
  active PCM. Startup retains its stricter headroom gate. At flush, verify the
  native source position and positive first render deadline; preserve the
  post-enqueue whole-window exhaustion check.
- Keep admitted/held source endpoints distinct from native-enqueued endpoints.
  Cohort duration derives from its first render time and total source frames,
  not the final packet's timestamp jitter. Capture discontinuities still retire
  invalid mappings rather than compressing missing audio.
- Count original packets, not native buffers, against admission limits. Held
  packets count as pending. Unique generation-scoped completion tickets release
  their exact packet weight once; old or duplicate callbacks release nothing.
- Keep `.dataPlayedBack`: completion also protects audible predecessor
  retirement. `.dataRendered` is not an interchangeable performance switch.
  Stop, pause, forced resync and configuration recovery discard the correct held
  generation; never append its tail into a replacement timeline.

The sustained enqueue-cost test must exercise the actual player, preserve its
native PCM marker prerequisite, and pass independently of the native batching
reference. Tail, capacity, cutover and previous underrun/enqueue-race regressions
remain required. Do not call a fixture's reseeded native queue equivalent to the
player ledger while any PCM is still held outside that queue.

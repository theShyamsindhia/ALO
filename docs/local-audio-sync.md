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

## Receiver correction and diagnostics

Room settings → Automatically keep this Mac in sync is enabled by default and persists per Mac. A fresh measured error of at least 40 ms must persist for one second before hard realignment. Corrections have an eight-second cooldown; missing/stale samples and pauses clear accumulated evidence. Small errors continue to use the existing bounded ±1% playback-rate correction. This preference controls optional drift realignment, not mandatory recovery from a stopped render clock or changed audio device.

Updated receivers advertise ownership of this policy in their playback report. The updated host does not run its old competing lateness-triggered reset against these receivers. Legacy receivers retain their previous host fallback. Manual Sync this Mac still targets only the local receiver; no automatic room-wide reset is added. Each listener should enable their own local setting.

Settings → Audio timing separates measured network round-trip, the actual agreed room playback delay, hardware output latency and fresh local drift. Drift is unknown when no current measurement exists; it is not displayed as a fabricated zero. Game RTT appears separately inside the fighter. Low game latency is good; neither game nor audio resync makes a slow network faster.

A call can change the output route, sample rate or Bluetooth microphone profile, or stop the render clock. Existing AVAudioEngine configuration-change and watchdog recovery rebuild or realign playback. A call on one receiver should not require every listener to resync. A call that interrupts the broadcaster's source can affect everyone because their source itself has stopped or changed. This implementation does not detect or inspect phone calls, and does not guarantee recovery timing on untested hardware.

The user's rapid-drift report was not reproduced on their hardware. The overlapping receiver/host correction path was a concrete code risk fixed here. Physical acceptance still requires AirPods/Bluetooth profile changes, wired devices, FaceTime/phone interruptions, sleep/wake, network loss and several Macs playing together. Automated policy tests establish thresholds, fresh-evidence requirements, cooldown and report compatibility; they do not establish audible call recovery quality.

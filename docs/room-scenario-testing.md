# Room scenario testing

Run on macOS with the project's Swift toolchain:

```sh
bash Scripts/test_room_scenarios.sh      # one pass
bash Scripts/test_room_scenarios.sh 10   # repeated socket/lifecycle soak
swift test --no-parallel                # full suite, including hardware lifecycle tests
```

The runner fails on the first failing pass and retains each run's output in a
printed temporary log directory. It does not install, launch, sign, or update
ALO; the release workflow also runs it before packaging. These focused scenarios do not advertise
rooms, capture hardware audio, change output devices, request permissions, or
read production room data.

## Real local network scenario

`LoopbackRoomScaleTests.mixedTrafficSurvivesListenerRestarts` combines production
`HostServer`, three `MeshControlPlane` instances, separate on-disk `RoomStore`s,
and headless TCP/UDP media receivers. A synthetic 48 kHz stereo source sends four
5 ms packets every 20 ms, independently of the control-plane activity.

The scenario starts broadcasting before listeners exist, then:

1. Adds an established listener and a late listener.
2. Sends concurrent chat and a targeted 48 kHz voice session while media flows.
3. Checks exact voice payloads, ordering, recipient isolation, and durable chat.
4. Reports increased output latency from the new listener; checks it does not
   move the established room timeline.
5. Stops/recreates the late listener three times with the same identity and disk
   store while checking that the remaining listener keeps receiving media.

Assertions cover media payload corruption, delivery gaps, capture-to-receive
age, continued delivery beyond the historical 3–5 second stall, chat persistence,
and unexpected durable-sync fallback. Printed timings are **network delivery
metrics, not measured acoustic synchronization**. Bounds allow normal test-host
scheduling jitter, but reject long stalls or growing delivery backlogs.

## Seeded delayed-network simulation

`RoomNetworkSimulationTests` uses real Automerge state/sessions and production
wire chunk encoding/newline decoding. A logical-time network models four devices
on a ring, independently delayed links, interrupted in-flight deliveries, two
isolated partitions, concurrent offline chat/queue edits, three restarts, healing
connections, and a fifth device joining with no history.

Each live TCP direction stays ordered. A disconnect discards its outstanding
messages and reconnect creates fresh sync sessions. Encoded messages are also
split across small, varying read boundaries to exercise partial-line decoding.
Chunk reassembly is done by the harness; the real socket scenario exercises the
production control-plane transport separately.

Seeds **7, 41, 991, 65537**, fixed actor identities, and deterministic events make
the schedule repeatable with the pinned Automerge version. Failures identify the
seed, node, and logical tick. The oracle independently tracks expected messages
and queue contents; success requires both convergence and network quiescence,
not just the absence of errors. These are logical network delays, not a model of
radio interference, packet codecs, or OS audio scheduling.

## Regression discovered by the simulation

Seed 7 repeatedly failed at logical tick 1226 before the fix: pending sync traffic
never settled. The wrapper discarded a received candidate when its visible heads
hadn't changed, also discarding changes awaiting missing dependencies. Automerge
can legitimately defer these changes even over ordered TCP. Retaining the bounded
candidate lets later sync rounds resolve them.

`RoomStatePendingDependencyTests` isolates this behavior without random timing:
withhold a parent change, deliver its child, edit locally, save/reload, then deliver
the parent. It also checks deferred invalid changes remain rejected and unresolved
changes cannot bypass the document-size limit.

## Still requires real-device QA

These tests do not run the full GUI/MeshSession lifecycle or render the received
audio through hardware. They cannot certify Bluetooth profiles, AirPods microphone
quality, echo, output switching, TCC permission dialogs, or audible multi-Mac drift.
They also do not exercise screen-capture previews or encoded video delivery.

Before a release touching those paths, run the signed app on at least two Macs:
start music before joining, talk both ways over the music, switch speakers to
Bluetooth, leave/rejoin repeatedly, disconnect another listener, and stop/restart
the broadcaster. Capture each Mac's debug logs and verify actual sound and shared
playback timing. Keep this device QA separate from the simulation pass/fail result.

# Shared real-time library engine

Rift Arena and Stick Fight both use `GameRealtimeEngine<Input>` in ALOCore and `GameRealtimeLoop` in ALO. New real-time library games must use these components rather than creating a second timer, prediction history, or remote-position smoother. Each activity has its own instance so it cannot share another game's match state. The implementation and policy are shared. Fourfold is local turn-based play and does not require a network frame loop.

## Timing and latency

- Fixed simulation and input sampling: 60 Hz.
- Host snapshots: 30 Hz, scheduled from simulation steps rather than timer callback count.
- At most six catch-up steps after a stall; no backlog of elapsed seconds to play through.
- Locally predicted movement with a bounded six-step replay of unacknowledged inputs. Hosts acknowledge inputs only after simulating them. Prediction cannot deal damage or decide results.
- Remote positions use one arrival-jitter estimator and interpolation buffer. Healthy connections add roughly one snapshot interval (33 ms) to remote presentation; the buffer adapts up to 83 ms under jitter. Extrapolation is capped at 33 ms, then freezes until a fresh snapshot instead of running a fighter offstage.
- Teleports, respawns, deaths, new rounds and new sessions reset or bypass interpolation. Rendering at 30, 60, 120 or 144 Hz does not change game speed.
- Missing input is neutral after 200 ms. Reconnecting appears after two seconds; absent players become bots after six seconds; an unresponsive activity host times out after twelve seconds.

Rift previously waited for host movement and used render-frame-dependent correction constants. It now predicts the local fighter and uses the same interpolation as Stick Fight. With an older Rift host that omits input acknowledgments, prediction is disabled safely; shared remote interpolation still works. All players should update ALO for the complete improvement.

## Transport

Both protocols run over existing authenticated direct room control connections. `GameSendQueue` owns a bounded lifecycle queue and the newest input/state per game/session stream. Replacing an obsolete frame cannot erase another game's input, and leaving one game cannot clear another game's queued traffic. `ArenaSendQueue` is a source-compatibility alias, not a separate implementation. Traffic remains ephemeral and separate from room history.

The transport is reliable TCP. Head-of-line blocking during packet loss, Wi-Fi interference and host CPU stalls remain physical constraints. This is authoritative networking with local movement prediction and a small remote interpolation buffer, not rollback combat or a zero-latency guarantee. WAN matchmaking and relay hosting are outside the current room architecture.

## Pause

The shared policy pauses the world only in offline practice. In multiplayer, Escape opens a local menu and releases your controls; host simulation, remote rendering and other players continue. Your fighter remains vulnerable. Closing/minimizing or switching focus likewise releases input. There is no global pause or hidden invulnerability. Leaving the activity host ends that match, while the ALO room stays connected.

## Checks

`GameRealtimeEngineTests` verifies frame-rate independence, bounded catch-up, sequence acknowledgments, jitter interpolation, outage extrapolation, respawn snapping, cross-game queue isolation, movement-only Rift prediction, and offline-versus-multiplayer pause. Game-specific session tests exercise actual join/ready/input/snapshot flows. Authenticated loopback tests verify both game protocols alongside chat. Native checks exercise game startup, rendering and menu behavior. Multi-Mac Wi-Fi testing remains necessary to quantify device-specific latency.

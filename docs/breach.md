# Breach — room demolition FPS

Breach is ALO's original four-seat, two-team tactical FPS. Open Games → Breach → Play. In an ALO room, host a match or join/watch an advertised match. `swift run alo breach` opens offline practice in a dedicated window. Fourfold (Connect 4) is hidden from the library; downloaded files are not deleted.

## Match

Two attackers face two defenders; bots fill empty seats. Everyone readies in the lobby; a host can start with three bots. First team to five rounds wins. Each round has a 15-second buy phase, 90 seconds to attack, and a 40-second planted timer. Hold Interact for three seconds at site A or B to plant, or five seconds near the planted device to defuse. Release or move away to cancel progress. A fallen carrier drops the bomb and a living attacker can recover it. Attackers win on detonation or defender elimination; defenders win on defuse, unplanted timeout, or elimination before planting. After planting, eliminating attackers alone does not stop the timer.

Players start with $800 and a pistol. Buy the VX-9 ($1,250), AR-24 ($2,400), or armor ($650) at spawn during the buy phase. Purchases, damage, rewards and results are validated by the match host. Kills and round outcomes award money, capped at $16,000. Dead players lose equipment at the next round; survivors retain it. Teammates block shots but do not take friendly fire.

## Controls and settings

WASD moves, Shift walks, mouse aims, left click fires, R reloads, E interacts, B opens equipment, and holding Tab shows team, kills/deaths, cash and health. Movement, reload and interaction keys are rebindable. Sensitivity, FOV, volume and shadows persist. Escape releases the mouse and opens settings. Offline practice pauses; online matches continue. Cmd W closes and leaves the game without leaving the ALO room.

A live join reserves a bot seat for the next round; the bot finishes the current round. Full matches can be watched. Missing guest input becomes neutral after 200 ms, absent members become bots after six seconds, and a guest returns to the briefing after twelve seconds without its host. Host departure ends that match while preserving the ALO room.

## Network and validation

`BreachPacket` v1 uses ALO's authenticated private/public room links and per-stream bounded queues. Simulation is fixed at 60 Hz and snapshots publish at 30 Hz. Guests predict only movement and replay unacknowledged inputs; money, bullets, bomb progress and winners are never predicted as authoritative. Remote positions are interpolated. Snapshots remain below 8 KB. Discrete fire/reload/purchase taps use priority action packets so movement coalescing cannot discard them. Sender membership, packet sequence, finite input values and snapshot structure are validated.

Tests cover economy, cover, ammunition, objectives, scoring, all-bot rounds, four linked human sessions and a spectator, late joins, stale packets, host departure, action queue pressure and actual authenticated localhost room transport. The UI purchase flow and keyboard/mouse lifecycle were inspected in a local preview. Cross-Mac Wi-Fi/GPU performance is not equivalent to localhost testing; hardware playtesting remains useful. There is no host migration or global matchmaking; matches run within ALO rooms. This original game does not claim Counter-Strike feature parity.

## Original assets

Scene geometry, weapons, team characters, site markers and effects are local SceneKit/procedural assets. `Sources/ALO/Resources/Breach/concrete.png` was generated with the built-in image-generation tool. Prompt: seamless square albedo of weathered grey poured concrete, subtle aggregate, pores, faint horizontal formwork impressions, mottled mineral discoloration, fine hairline cracks; even diffuse illumination, no shadows, perspective, objects, text or border; neutral medium grey, seamlessly tiling edges. All assets ship in ALO's resource bundle.

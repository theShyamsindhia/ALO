# Rift Arena

## Entry and presentation

The room gamepad opens Games, not a running game. The library lists Rift Arena and Fourfold, with explicit download, cancel, retry, verify, update and remove states. Selecting an installed game loads its presentation data; the fighter starts only after Play solo or both room players ready up. Ordinary room members receiving lobby advertisements do not start a simulation, render view, or timer. Library browsing creates no SpriteKit scene.

Rift uses original illustrated observatory scenery and fighter artwork, compressed into an approximately 856 KiB pack. Only small native engines and catalog metadata ship in the app. See [downloadable packs](game-library.md) for content releases and their limits. The app shell follows ALO's charcoal surfaces, system typography and muted accents. Player 1 is lavender; player 2 is clay, with text labels and state so color is not the only identifier.

## Play

- Three stocks and a three-minute match; tied timeouts resolve by stocks, then damage.
- Rising damage increases knockback. Directional light/heavy attacks have startup, active and recovery frames; one hit per attack, hit stun and simultaneous trades.
- Ground jump, two air jumps, one upward recovery, short invulnerable dodge with cooldown, fast fall and one-way upper platforms.
- Respawn protection ends on attack. Ring-outs remove stocks; results support another practice round or a shared ready-up rematch.
- Keyboard: A/D movement, Space jump, W/S aim, J light, K heavy, L dodge, Esc/P menu. Controller: left stick/d-pad movement and aim, A jump, X/Y attacks, right shoulder dodge, Menu for game menu. Click the arena to focus controls.
- Menu contains Overview, Controls and Settings, player identities/colors/stocks/eliminated state, volume, effects, restart/leave/fullscreen controls. Solo pauses; a network match continues while a participant inspects the menu, with their input cleared.

The same session remains active across embedded, pop-out and fullscreen presentation. Hidden render surfaces pause; hidden practice pauses. Only participants in an explicitly started online match continue its simulation/connection heartbeat. Leaving the activity ends participation. Game sound has an independent volume control and releases its audio engine after idle.

## Room protocol

Two players, both ready; up to eight spectators may enter after play starts. Player slots cannot change mid-match. The host simulates 60 Hz; guests send input at 30 Hz and receive authoritative state at 20 Hz. Guest rendering smooths small corrections; spectators currently use snapshots directly. This is LAN-oriented snapshot netcode, not rollback/prediction netcode. Guest scheduling can add up to roughly 100 ms before network round-trip and rendering; this is a scheduling estimate, not a measured latency benchmark. Shared TCP can stall under packet loss, and frame coalescing can lose brief button presses under backpressure. Competitive online play requires a sequenced input/acknowledgement protocol, prediction/reconciliation or rollback, and latency/loss playtests.

Game packets are versioned, bounded to 8 KiB, direct-link only and ephemeral. They never enter durable room state/chat. Peer identity, session UUID, monotonic sequence, round number, numeric bounds and input directions are checked. Per-link send state permits one in-flight packet, a bounded priority lifecycle queue, and one replaceable latest frame. Receive traffic is capped at 90 packets/second/peer. Old rematch snapshots are rejected. Stale controls release after 250 ms; disconnected match peers time out after five seconds. Host departure ends the match for players and spectators. Game traffic inherits the room coordination channel's privacy limits; see [privacy](room-privacy.md).

## Scope and verification

This is an original two-fighter, one-arena game. It does not copy Brawlhalla assets, claim competitive parity, implement rollback, or support remote Internet matchmaking. Art uses animated whole-character sprites and procedural impacts, not a full frame-by-frame animation set. Controller mappings are implemented; physical controller and multi-Mac latency/feel tests remain required.

`ArenaTests` verifies deterministic simulation, attack timing, jump/recovery/dodge/stock behavior, bounded snapshots, ready-up, spectators, round-safe rematches and lifecycle backpressure. `ArenaTransportTests` exchanges ephemeral game traffic alongside chat over authenticated private-room loopback connections. Native UI checks cover library entry, controls, pause, rendering and fullscreen. The lifecycle stops idle-library timers and pauses hidden rendering; an Instruments energy benchmark remains release QA.

References: [Brawlhalla](https://www.brawlhalla.com/), [movement](https://brawlhalla.wiki.gg/wiki/Movement), [attacks](https://brawlhalla.wiki.gg/wiki/Attacks).

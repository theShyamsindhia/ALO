# Rift Arena

## Entry and presentation

The room gamepad opens Games, not a running game. The library lists Rift Arena and Fourfold, with explicit download, cancel, retry, verify, update and remove states. Selecting an installed game loads its presentation data; the fighter starts only after the creator starts a room match and all human players ready up. Ordinary room members receiving lobby advertisements do not start a simulation, render view, or timer. Library browsing creates no SpriteKit scene.

Rift uses original illustrated observatory and moon-garden scenery and fighter artwork, compressed into an approximately 3.43 MiB version-4 pack. Only small native engines and catalog metadata ship in the app. See [downloadable packs](game-library.md) for content releases and their limits. The app shell follows ALO's charcoal surfaces, system typography and muted accents. Player 1 is lavender; player 2 is clay, with text labels and state so color is not the only identifier.

## Play

- Choose Nova, Atlas, Ember, Wisp or Rook and Hollow Observatory, Moon Garden, or Skybridge. The host chooses the map; all players and spectators receive the same geometry. A room match supports up to four combatants plus eight spectators. The creator can add or remove bots before the round. Late joiners inherit a live bot slot without resetting its stocks, damage or fighter; a full match opens in spectator mode.
- Three stocks and a three-minute match; tied timeouts resolve by stocks, then damage.
- Rising damage increases knockback. Directional light/heavy attacks have startup, active and recovery frames; one hit per attack, hit stun and simultaneous trades.
- Ground jump, two air jumps, one upward recovery, short invulnerable dodge with cooldown, fast fall and one-way upper platforms.
- Respawn protection ends on attack. Ring-outs remove stocks; results support another practice round or a shared ready-up rematch.
- Keyboard: A/D movement, Space jump, W/S aim, J/Z light, K/X heavy, L/C dodge, Esc/P menu. Controller: left stick/d-pad movement and aim, A jump, X/Y attacks, right shoulder dodge, Menu for game menu. Click the arena to focus controls. The main game flow is room creation with configurable bots; private training remains an internal test utility.
- Menu contains Overview, Controls and Settings, player identities/colors/stocks/eliminated state, volume, effects, restart/leave/fullscreen controls. Internal practice pauses; a network match continues while a participant inspects the menu, with their input cleared.

The same session remains active across embedded, pop-out and fullscreen presentation. Hidden render surfaces pause; hidden practice pauses. Only participants in an explicitly started online match continue its simulation/connection heartbeat. A late player can enter any unused fighter slot without resetting the round, or take over a living bot while preserving that fighter's state; full matches remain available to spectators. Leaving the activity ends participation. Game sound has an independent volume control and releases its audio engine after idle.

The round countdown presents the map and versus names with fading cinematic bars. Layered parallax follows the fighters, foreground foliage sways, motes drift, and shadows project onto platforms. Reduced motion disables decorative movement. Nova and Atlas use procedural joint animation rather than baked animation clips. The rig motion and combat balance still need human playtesting.

## Room protocol

Two to four fighters, with every human ready and bots automatically ready; up to eight spectators may enter after play starts. Human players can enter unused slots or take live bot slots mid-round. Disconnected players become bots; host departure ends the round. The host simulates 60 Hz; guests send input and receive authoritative state at 30 Hz. Guest and spectator rendering use bounded velocity presentation between snapshots and smooth authoritative corrections. This is LAN-oriented snapshot netcode, not rollback/prediction netcode. Guest scheduling can add roughly 70 ms before network round-trip and rendering; this is a scheduling estimate, not a measured latency benchmark. Shared TCP can stall under packet loss, and frame coalescing can lose brief button presses under backpressure. Competitive online play requires a sequenced input/acknowledgement protocol, prediction/reconciliation or rollback, and latency/loss playtests.

Version 4 game packets carry the map and echoed monotonic timing probes. Both players must use an app supporting this protocol; older-version packets are rejected rather than simulating mismatched maps. The game footer shows smoothed measured round-trip latency (not end-to-end button-to-pixel delay). Resyncing audio cannot reduce game RTT.

Game packets are versioned, bounded to 8 KiB, direct-link only and ephemeral. They never enter durable room state/chat. Peer identity, session UUID, monotonic sequence, round number, numeric bounds and input directions are checked. Per-link send state permits one in-flight packet, a bounded priority lifecycle queue, and one replaceable latest frame. Receive traffic is capped at 90 packets/second/peer. Old rematch snapshots are rejected. Stale controls release after 250 ms; disconnected match peers time out after five seconds. Host departure ends the match for players and spectators. Game traffic inherits the room coordination channel's privacy limits; see [privacy](room-privacy.md).

## Scope and verification

This is an original five-fighter game with three arena layouts. It does not copy Brawlhalla assets, claim competitive parity, implement rollback, or support remote Internet matchmaking. Combat uses original articulated SpriteKit rigs: torso, head, scarf, shoulders, elbows, wrists, hips, knees, and weapons. Geometry is constructed once; per-frame pose updates allocate no new rig nodes or paths. Raster fighter artwork is no longer used as the combat sprite. Background, transparent islands and foreground foliage move at different depths with a bounded tracking camera; physical platforms remain deterministic. Controller mappings are implemented; physical controller and multi-Mac latency/feel tests remain required.

`ArenaTests` verifies deterministic simulation, attack timing, jump/recovery/dodge/stock behavior, bounded snapshots, ready-up, spectators, round-safe rematches and lifecycle backpressure. `ArenaTransportTests` exchanges ephemeral game traffic alongside chat over authenticated private-room loopback connections. Native UI checks cover library entry, controls, pause, rendering and fullscreen. The lifecycle stops idle-library timers and pauses hidden rendering; an Instruments energy benchmark remains release QA.

References: [Brawlhalla](https://www.brawlhalla.com/), [movement](https://brawlhalla.wiki.gg/wiki/Movement), [attacks](https://brawlhalla.wiki.gg/wiki/Attacks).

The library shows a brief in-room invitation when a peer opens a match; this is ephemeral and does not enter chat history or OS notifications. Its leaderboard is a bounded local record of completed room matches with at least two humans. It does not claim global or cheat-resistant ranking. See [game records](game-records.md).

## Fighter identity and moves

Both players may choose the same fighter. Character colours stay faithful to the portrait art; player number, roster colour and small costume accents distinguish mirror matches. Portraits appear in selection; combat uses separate animated limbs and weapons rather than moving the portrait as one rigid image.

Each of the five fighters has twelve deterministic move profiles: light/heavy × forward/up/down × grounded/aerial. Nova uses blade cuts, lunges and dives; Atlas uses gauntlet jabs, uppercuts and ground slams. The controls tab lists the exact move names for the selected fighter. Heavies are tap-triggered signatures, not charge attacks. Weapon pickups/throws, wall jumps, gravity cancels, charge mechanics and competitive combo balance remain outside this build.

Platforms combine original compressed stone artwork with bounded static masonry, bevels, cracks, inlays, moss and roots. The collision edge remains unchanged. Static nodes bake once into a sprite per platform when the SpriteKit view becomes available.

The host selects Easy, Normal or Hard bots before creating a match. Bots use deterministic, character-aware move selection and recovery rules; they do not learn from a player or change difficulty silently. Bot slots cycle through the roster. Five selectable fighters does not change the four-combatant match limit. Balance and difficulty labels need human playtesting. Starting and resuming request keyboard focus once; switching away clears held keys so chat and other windows do not send game input.

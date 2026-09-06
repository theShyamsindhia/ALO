# Stick Fight implementation and verification

ALO's Stick Fight is a native implementation inspired by Landfall's game. It has original procedural artwork and a smaller arena/weapon set; it is not a port of Landfall's proprietary simulation or assets. The reference mechanics checked against the [official controls FAQ](https://landfall.se/stickfightfaq) are mouse punch/fire, mouse-directed aim, right-click blocking, WASD movement/jumping, and F to throw weapons. The [official press kit](https://landfall.se/stick-fight-press-kit) describes the original's physics-driven fighting and procedural animation. Offline bots are an additional ALO practice feature.

## Units and movement

The authoritative world is 1,000 × 600 points. All velocity values use points/second; accelerations use points/second². The simulation advances exactly 1/60 second per step and the session accumulates monotonic elapsed time. The catch-up budget is bounded to prevent a stalled UI from running hundreds of old frames.

Gravity is 1,750 points/s² and jump launch speed is 640 points/s. Vertical integration uses `y += vy * dt - 0.5 * g * dt²`, then `vy -= g * dt`. An unobstructed jump therefore has a theoretical apex at 0.366 seconds and rises 117.03 points. Air jumps and wall kicks extend traversal deliberately. Ground acceleration is 2,800 points/s², airborne steering is 1,400 points/s², and normal running speed is 340 points/s. Starting from rest reaches that speed in about 0.121 seconds on the ground. Input does not overwrite stronger knockback velocity.

Uncommanded velocity decays exponentially (`v *= exp(-drag * dt)`). Jump buffering and coyote time each last six simulation ticks (100 ms); wall contact is remembered for five ticks. These tolerances let an input just before landing or just after leaving an edge register predictably.

## Combat and collision

Hits add velocity impulses instead of replacing momentum. Fighter contact uses equal-mass separation, three constraint iterations, and restitution 0.12. Swept crossing detection prevents two fast fighters from changing sides without colliding. Platform walls constrain the positional correction. Gun recoil applies the opposite bullet momentum using a projectile-to-fighter mass ratio of 0.018. Scattergun pellets each contribute recoil. Thrown weapons use a ballistic path and retain remaining ammunition when recovered.

Projectiles use substeps for thin-target collision, and at most 16 live projectiles enter a snapshot. Arena hazards use their actual collision geometry: rectangles for spike strips and nearest-point circle/rectangle intersection for the foundry's pendulum. The pendulum is analytic (`theta = 0.72 sin(sqrt(g/L) t)`, `L = 380`), preventing cumulative drift between peers. This is a controlled harmonic approximation, not an exact large-angle pendulum solver.

Character ragdolls are presentation effects. Their limb constraints and collisions do not alter authoritative hitboxes, damage, or winners. This keeps network outcomes independent of rendering frame rate.

## Session behavior

The [shared real-time engine](game-realtime.md) supplies scheduling, input history, jitter buffering, and pause policy for both Stick Fight and Rift Arena. The host decides hits, pickups, deaths, and round results. Guests immediately predict their own movement and replay unacknowledged movement after receiving a snapshot. Reconciliation cannot fire a second shot or award a local round. Host snapshots run at 30 Hz; obsolete queued snapshots are replaced. Late joins spectate until a lobby opens. Dropped inputs neutralize after 200 ms. A missing guest becomes a bot after six seconds; a client without host responses retries and exits the activity after twelve seconds. Leaving the activity host ends this fight, not the room.

## Verification

The focused Swift tests cover ballistic motion, momentum, contact separation, wall kicks, jump buffering, recoil, weapon throws, moving hazards, malformed snapshots, packet size, round completion, joining/readiness, late spectating, stale sequence rejection, input expiry, disconnect, prediction, and library integration. An authenticated loopback test sends Stick Fight traffic alongside room chat. Native UI checks cover library entry, practice startup, first-frame rendering, focus, pause/resume, controls, and arena presentation. Physical multi-Mac Wi-Fi latency still requires testing on the participating devices.

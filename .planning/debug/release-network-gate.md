---
status: investigating
trigger: "ALO 0.14.9 release CI must pass without weakening the live networking or audio-delivery gates."
created: 2026-09-06
updated: 2026-09-06
---

## Symptoms

- expected: The full optimized regression suite passes, then the updater-safe app is signed, notarized, verified and attached to the release.
- actual: CI stops before packaging after intermittent local endpoint collisions, mesh convergence failures and a stressed eight-listener delivery minimum of 48 packets against the unchanged 50-packet floor.
- errors: Network.framework reports EADDRINUSE for loopback control connections; relayed and secure meshes fail to converge; bounded eight-listener delivery remains timely but occasionally falls below the per-listener floor.
- timeline: The archive incompatibility was fixed at ac9c01c. The first 0.14.8 run exposed the existing live-network gate; 0.14.9 reproduced it after Raj's initial socket-order change.
- reproduction: Publish or dispatch the Apple Silicon workflow and run the complete optimized test suite on macos-15 with Xcode 26.3.

## Current Focus

- hypothesis: Listening and dialing peers need reusable local TCP endpoints, and an idle bounded sender rejects a fresh pending burst using the final stale completion sample before its existing idle reset runs.
- test: Assert local endpoint reuse on all room TCP profiles; reserve the loopback control connection before either media listener; reproduce an idle sender's final slow completion with fresh pending PCM; combine 35ms capture catch-up with batched deterministic completions.
- expecting: Mesh and loopback sockets stop colliding, every recovering sender gets a fresh probe, the strict 50-packet floor and all existing latency ceilings pass unchanged.
- next_action: Implement the focused regressions and minimum production fixes, then run release CI.

## Evidence

- timestamp: 2026-09-06T18:20:00+05:30
  observation: CI 34033417657 delivered bounded stressed audio with maximum age below 250ms but one listener received 48/200; sender accounting showed admission rejection rather than hidden transport loss.
- timestamp: 2026-09-06T18:20:00+05:30
  observation: The same run logged POSIX EADDRINUSE after the loopback helper had opened UDP but before its outbound control connection reached ready; multiple public and secure mesh convergence tests then timed out.
- timestamp: 2026-09-06T18:20:00+05:30
  observation: HostServer clears completion evidence only after drainAudio has emptied pending work. When the last in-flight send completes slowly, fresh pending packets are evaluated and rejected before that reset.
- timestamp: 2026-09-06T18:52:00+05:30
  observation: Release run 34035289490 reproduced the remaining idle-path fault deterministically: two listeners stopped at sequences 176 and 181, a late-join run left an established listener at 40 packets, and a delayed-capture run reached 49. All four failures stayed below the unchanged 250ms latency ceiling and were admission drops, not transport loss.

## Eliminated

- hypothesis: The updater-safe archive change caused the networking regression.
  reason: The package script and ZIP gate do not execute until after tests; HostServer and mesh runtime were unchanged by ac9c01c.
- hypothesis: Lowering the live packet threshold is an acceptable release fix.
  reason: It would hide the per-listener starvation the gate is designed to catch and is explicitly outside the requested quality bar.

## Resolution

- root_cause:
- fix:
- verification:
- files_changed:

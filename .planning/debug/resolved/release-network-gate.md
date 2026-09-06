---
status: resolved
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
- next_action: Resolved in ALO 0.14.11; retain the strict networking, latency, archive and clean-distribution gates.

## Evidence

- timestamp: 2026-09-06T18:20:00+05:30
  observation: CI 34033417657 delivered bounded stressed audio with maximum age below 250ms but one listener received 48/200; sender accounting showed admission rejection rather than hidden transport loss.
- timestamp: 2026-09-06T18:20:00+05:30
  observation: The same run logged POSIX EADDRINUSE after the loopback helper had opened UDP but before its outbound control connection reached ready; multiple public and secure mesh convergence tests then timed out.
- timestamp: 2026-09-06T18:20:00+05:30
  observation: HostServer clears completion evidence only after drainAudio has emptied pending work. When the last in-flight send completes slowly, fresh pending packets are evaluated and rejected before that reset.
- timestamp: 2026-09-06T18:52:00+05:30
  observation: Release run 34035289490 reproduced the remaining idle-path fault deterministically: two listeners stopped at sequences 176 and 181, a late-join run left an established listener at 40 packets, and a delayed-capture run reached 49. All four failures stayed below the unchanged 250ms latency ceiling and were admission drops, not transport loss.
- timestamp: 2026-09-06T19:08:00+05:30
  observation: Run 34035999118 cleared the late-join and delayed-capture packet floors. Its focused idle-path regression showed sequences 8...10 were rejected before the final completion because retry eligibility compared their 80...90ms capture age with the sender's 80ms queue-wait limit, despite zero queue residence and more than 100ms of room admission budget remaining.
- timestamp: 2026-09-06T19:21:00+05:30
  observation: Allowing those older packets to wait in run 34036728533 raised delivery counts but produced 250.7...282.6ms packet ages, violating the unchanged 250ms playout bound. The busy-path capture-age guard is therefore required; the separate terminal-sequence assertion conflicted with the bounded-latency policy, while the test's strict packet floor and maximum-gap checks already detect starvation and premature cessation.

## Eliminated

- hypothesis: The updater-safe archive change caused the networking regression.
  reason: The package script and ZIP gate do not execute until after tests; HostServer and mesh runtime were unchanged by ac9c01c.
- hypothesis: Lowering the live packet threshold is an acceptable release fix.
  reason: It would hide the per-listener starvation the gate is designed to catch and is explicitly outside the requested quality bar.

## Resolution

- root_cause: Loopback helpers could reserve media endpoints before their outbound control connection, causing local TCP collisions and cascading mesh failures. Separately, a fully drained bounded audio sender evaluated fresh pending PCM using the final stale completion sample. One deterministic terminal-sequence assertion also contradicted the policy's intentional stale-tail shedding even though the strict packet floor, packet-age ceiling and continuity checks remained authoritative.
- fix: Enable local TCP endpoint reuse, reserve loopback control connections before media listeners, clear bounded sender service history only when the path is fully idle, and express terminal behavior through the unchanged delivery floor, 250ms age bound and maximum-gap invariant. The updater package also flattens framework links and CI rejects any ZIP symlink before publication.
- verification: ALO 0.14.11 run 34038044161 passed 881 optimized tests in 148 suites, Developer ID signing, Apple notarization and stapling, Gatekeeper, arm64 validation, the no-symlink updater check, and clean-machine game-resource launch. Independent verification of the published ZIP and DMG repeated version/build, signature, notarization, Gatekeeper, resource and no-symlink checks successfully.
- files_changed:
  - Sources/ALO/HostServer.swift
  - Sources/ALONetworking/LocalNetworkParameters.swift
  - Sources/ALONetworking/SecureNetworkParameters.swift
  - Sources/ALO/RoomMediaSecurity.swift
  - Tests/ALOTests/AudioSenderBurstTests.swift
  - Tests/ALOTests/DeterministicAudioFanoutTests.swift
  - Tests/ALOTests/LoopbackRoomScaleTests.swift
  - Scripts/package.sh
  - .github/workflows/build-apple-silicon.yml

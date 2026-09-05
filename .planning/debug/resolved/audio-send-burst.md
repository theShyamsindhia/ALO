---
status: resolved
trigger: "User authorized investigating and fixing the audio-delivery release blocker before publishing 0.13.49."
---

## Current Focus

- root_cause: A single latest-only pending slot discarded fresh bursts; the replacement queue's initial admission estimate also understated growing in-flight work after delayed capture.
- resolution: Verified and published ALO 0.13.49 from the successful signed CI commit 39b152e8f275ec5d56037b7485c1a4bb0a52f83e.

## Evidence

- CI 33963911781 on c7690eb: 297/298 tests passed; direct bounded eight-peer delivery was 121/200, below the unchanged 190 minimum. No release was published.
- HostServer and the failing integration fixture were unchanged by the UI/mute patch.
- Deterministic baseline reproduces loss with three fresh four-packet callbacks: sent 0...7 and 11, dropped 8...10. Both capture-age variants fail without scheduler timing assumptions.
- Existing commits 6aacbf6, b7bac5e and b18df8b contain the relevant sender fix. Reused only HostServer, its drop diagnostics, and sender/integration tests. Did not import their version/workflow edits or the later unrelated video and drift changes.

## Fix

- Preserve short FIFO bursts with bounded count, span and wait; return to latest-only under sustained congestion.
- Reject expired work and respect the remaining playout budget; clear stale service estimates on idle recovery.
- Discard pending audio on timeline/connection boundaries and ignore obsolete connection completions.
- Retain the 190-packet fast-link delivery and original latency limits. Measure actual submitted transport drainage separately from intentional unsent expiry; account for every captured packet and enforce continuous bounded progress.

## Verification

- Baseline log: /tmp/alo-audio-burst-baseline.log (both fresh-burst variants fail on the old sender).
- Fixed focused suite: 16 tests passed; fast eight-peer delivery 200/200, original delivery/latency thresholds unchanged.
- Full serial suite: 313 tests passed in 183.7 seconds. Log: /tmp/alo-0.13.49-all-tests.log.
- The release remains unpublished pending CI, signing and notarization. No installed app or physical multi-Mac session was altered.

## Release-gate follow-up

- CI 33965227394 passes deterministic sender tests but its live timing probe also fails the unconstrained-link control (129 ms vs 100 ms), pointing to fixture scheduling as a separate issue.
- Existing instrumented run 33961973819 records simulated capture waking 100–200 ms late, before outbound admission; it uses Foundation relative sleeps. Normal run-to-run local tests pass.
- Replace the fixture's relative sleep with absolute mach_wait_until deadlines on the same monotonic timebase as its capture stamps; use production-equivalent user-interactive priorities for capture and peer queues. Preserve 48 kHz offered load, explicit 35 ms wake injection, all delivery/latency limits, and actual transport drainage.
- An optimization-only test experiment hit the existing SwiftPM executable-target test-entry issue (ALO receives --test-bundle-path). No compiler flag or workflow change was retained.
- Monotonic fixture checks: 14 targeted sender/fanout tests pass; normal capture wake delay stays within 12 ms and deliberate 35 ms oversleep remains exercised. All 23 real-loopback tests pass with unchanged packet and latency thresholds.
- CI 33966074758 still shows 135/200 direct bounded delivery and capture wake delays up to 195 ms with the absolute timer. It also failed two connection setup checks. Precise sleep alone does not prevent runner scheduling/throttling.
- Next falsifiable check: scope Foundation's latency-critical user activity to runRoom, paired with defer on all paths. The headless fixture opens no real audio device; unlike an active audio session it otherwise provides no process activity assertion. Local SDK NSProcessInfo.h documents this option for precise audio/video timers and I/O. No production power policy or threshold change.
- CI 33966847205: 200/200 direct delivery for every peer, and connection checks passed. One remaining stress miss: maximum packet age 280ms under 35ms injected oversleep. Local full suite still passed 313 tests.
- Reproduced the remaining miss deterministically with 110ms capture oversleep: maximum age 274.184ms. Two early completions understate service for packets still in flight. A focused two-completion test also fails: old capture is admitted when six outstanding sends need another 112ms.
- Add the recent mean completion interval times outstanding depth to admission budgeting, alongside the existing worst completed-send duration. Reset these samples on full idle and connection replacement. A maximum-interval experiment over-pruned live delivery and was rejected; the mean preserves throughput while accounting for backlog.
- Both new regressions and all 38 focused sender/deterministic/real-loopback tests pass. Delayed deterministic maximum age is 234.424ms; fast real links deliver 200/200 per peer; stressed real final ages are 144–154ms. No delivery or latency limits changed. Logs: /tmp/alo-delayed-capture-budget.log, /tmp/alo-flight-rate-baseline.log, /tmp/alo-flight-rate-mean-fixed.log.
- Final local full suite on bb809b0: 315 tests passed in 175.1 seconds. Log: /tmp/alo-0.13.49-rate-all-tests.log. Signed CI preflight: 33967509740.
- CI 33967509740 still fails live metrics with source wakes up to 191ms. Found a concrete fixture error in the earlier pacing edit: dispatch_sync explicitly does not observe queue QoS (local SDK dispatch/queue.h lines 283–298). Reuse the asynchronous capture/timeline pattern from e585040, retain absolute deadlines/activity, and assert the actual worker QoS. No source deadline rebasing or assertion weakening.
- CI 33968027664 on 39b152e passes all 315 tests (210.7s), signing, both Apple notarizations, stapling, architecture checks and Gatekeeper. Fast eight-peer delivery is 200/200 per peer for both wake variants. Stressed maximum packet age is 231/233ms, below 250ms, with final age 221/203ms. Local optimized build also passes. Release artifacts are being downloaded for publication; the installed app remains untouched.

## Publication

- Published https://github.com/theShyamsindhia/WERAI/releases/tag/v0.13.49 with the ZIP and DMG from CI 33968027664, not the local ad-hoc build. Release is non-draft and non-prerelease; both assets are uploaded.
- Downloaded artifacts independently passed arm64, version 0.13.49/build 80, code signature, stapled ticket and Gatekeeper checks on this Mac.
- ZIP SHA-256: 1d26e3aaec6057df4ad45d8b536b7bb54b5c30d30b0cb958c9e3f465ad46de6b.
- DMG SHA-256: 118e805ce4acc0c44c46c64d714b8e03ff944313db50e1c827c1cf8c3644c22c.
- No installed app replacement, live room interaction, or physical multi-Mac/Bluetooth listening test was performed.

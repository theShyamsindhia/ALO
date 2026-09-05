---
status: resolved
trigger: "User authorized investigating and fixing the audio-delivery release blocker before publishing 0.13.49."
---

## Current Focus

- hypothesis: A single latest-only pending slot drops fresh audio when capture callbacks briefly outpace completion dispatch, even without link congestion.
- next_action: Rerun the signed release gate and publish only after verified downloads exist.

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

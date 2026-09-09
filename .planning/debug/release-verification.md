---
status: verifying
trigger: "okay fix this and push them in the release"
---

## Symptoms

0.15.5 release workflow passed all tests, but independent verification attempt 1
failed six loopback admissions with EADDRINUSE. Attempt 2 passed all Swift tests,
but a Chromium download fixture asserted after teardown and overfulfilled XCTest.
Expected: all strict gates pass without retries or altered timing thresholds.

## Current Focus

hypothesis: both blockers are test-fixture mismatches, not changes required to
production audio or networking.
next_action: run all strict CI gates for the 0.15.6 candidate before stable publication.

## Evidence

- CI 34373948217 attempt 1: six EADDRINUSE failures before peer admission.
- CI attempt 2: 25,000-byte fixture later reports fallback total 312,500 (8%), after
  its History database is removed; callback asserts in a subsequent XCTest case.
- Adjacent FolderFileDownloadMonitorIntegrationTests already documents callbacks
  outliving stopMonitoring and uses TransferObservation to close at teardown.
- Release 34373969118 passed 384 XCTest, 1,392 Swift tests and seven scenarios.
- Native occupied-source probe with bare NWParameters.tcp reproduced EADDRINUSE;
  LocalNetworkParameters.tcp reached ready on the same setup. Another fixed 32
  reusable-source connect/cancel lifecycles passed without retries. Evidence:
  /tmp/alo-release-blockers.GAJo5y/socket-evidence.log.
- Production Receiver uses LocalNetworkParameters.tcp, but the headless test
  peer default was bare .tcp. The fixture now matches the production profile.
- Added deterministic forced-source admission coverage while retaining the
  existing explicit non-reusable collision test and cancellation assertions.
- Chromium fixture now uses the adjacent TransferObservation, closes before
  teardown and asserts exact captured bytes/progress in its own test body.
  Repeated, late and early-teardown callback coverage was added.

## Constraints

Preserve audio timing, admission checks and cancellation assertions. Do not
retry connections to hide collisions or weaken assertions. Work inline using
the debugging skill; symptoms and implementation approval are already provided.

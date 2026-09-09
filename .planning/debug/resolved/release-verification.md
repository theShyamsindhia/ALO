---
status: resolved
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
next_action: none; both strict pipelines passed for the 0.15.6 candidate.

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
- Verification 34379536430 and release 34379535849 both passed at
  0f89e554df5500f57b417d3f711e052e5839bd72: 385 XCTest cases, 1,393 Swift tests,
  seven room scenarios, Mac/iOS builds, signing, notarization and clean package
  checks. No rerun or weakened threshold was needed for this candidate.
- Local downloaded ZIP passed codesign and Gatekeeper; DMG passed codesign and
  hdiutil checksums. Published asset SHA-256 values match the verified artifacts.

## Resolution

The headless peer now uses the production TCP profile; the deterministic
reserved-source test joins while the non-reusable collision test still rejects.
The Chromium fixture uses the existing one-shot observation with exact progress
assertions in the test body, safely closed before removing its History database.
Production networking/audio and the monitor's multiple-snapshot contract were
not modified. A physical two-Mac video session remains outside this validation.

## Constraints

Preserve audio timing, admission checks and cancellation assertions. Do not
retry connections to hide collisions or weaken assertions. Work inline using
the debugging skill; symptoms and implementation approval are already provided.

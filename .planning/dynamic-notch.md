# DynamicNotch integration

Branch: `codex/dynamic-notch`, isolated worktree based on `d4e6895`.
Reference: `/Users/zex/Desktop/Files/Refrence Repo/DynamicNotch-main`.

- [x] Inspect ALO settings/presentation and reference motion with sub-agents.
- [x] Preserve the entire original source repository under `Vendor/DynamicNotch`.
- [x] Copy original shape, spring, transition, and layout files into ALO without recreating them.
- [x] Retain upstream GPL-3.0 license and record compiled-copy SHA-256 provenance.
- [x] Add opt-in Notch menu beside the existing floating-bar settings.
- [x] Embed ALO's current media/voice/chat/queue/people controls in a notch adapter.
- [x] Add persisted hover, display, island-style and five motion-preset settings.
- [x] Review lifecycle, display geometry, hit testing, and reduced motion.
- [x] Build and run focused tests.
- [x] Verify rendered compact/expanded UI.
- [x] Complete feature/settings inventory and final limitations.

## Scope

The full upstream source is available locally. Only the dependency-light notch primitives
are compiled into ALO. Additional system features are listed in `docs/dynamic-notch-features.md`;
they are not presented as enabled controls until their services and permissions are integrated.
The original DynamicNotch app entry point, updater feed, identity, and permission startup
are not used by ALO.

## Initial room-only implementation (superseded by full integration below)

Talk settings → Notch: Show room in notch; Expand on hover; Floating island style;
Prefer built-in display; Motion (Snappy/Fast/Balanced/Slow/Relaxed).
The notch is off by default, visible only in a live room, and reuses existing room actions.

## Validation

- `swift build`: passed.
- `swift test --filter ALONotchTests`: four tests passed, including four native render cases.
- Existing chat scroll/layout regression suite: ten tests passed.
- Compact, expanded room, expanded chat, and island PNGs visually inspected.
- Full 790-file reference snapshot and all nine compiled originals verified byte-for-byte.
- `git diff --check`: passed.

Manual follow-up: exercise pointer movement, physical display changes/full-screen Spaces,
and multi-Mac room playback on hardware. Native render tests do not establish those outcomes.
At the initial room-only checkpoint, no production app was replaced and no branch was pushed.

## Full feature integration (requested follow-up)

- [x] Merge latest origin/main changes without disturbing other active branches.
- [x] Compile the full original feature engine as a separate ALO module.
- [x] Remove standalone onboarding/updater/donation dependencies from the compiled app.
- [x] Default all extra features and home pages to off; isolate preferences.
- [x] Add master/feature lifecycle gating and shared ALO notch hosting.
- [x] Expose original feature settings through ALO Notch Settings.
- [x] Add packaged resources, permission descriptions and third-party notices.
- [ ] Complete module and full-app builds, fix diagnostics.
- [ ] Run original feature regression tests plus opt-in/lifecycle tests.
- [ ] Visually verify the settings and enabled feature surfaces.
- [ ] Measure installed size and idle resource use; confirm disabled services remain stopped.
- [ ] Run release/room/iOS checks applicable to main.
- [ ] Commit, fast-forward main and push after verification.

## Visual correction requested after preview review

- [x] Remove the oversized room-bar wrapper and duplicate compiled primitives.
- [x] Use original panel factory, host view, hit areas and activity renderer.
- [x] Adapt room playback data/commands to the original player; Room media defaults off.
- [x] Render original player, battery and tray, including non-notch island mode.
- [x] Fix macOS 15 reader destructor compatibility and actor-aware XCTest fixtures.
- [ ] Verify the full corrected suite and packaged app; show/open ALO Dev.
- [ ] Record final size and CI evidence, then push main without overwriting newer commits.

---
status: resolved
trigger: "The 0.14.0 GitHub Actions build fails ArtworkHeaderPresentationTests while the same test passes locally; fix it and make the release good to publish."
created: 2026-09-05
updated: 2026-09-05
---

# Symptoms

- Expected: the album-derived multi-colour header renders in both light and dark appearance, and the release validation suite passes on the Apple Silicon GitHub runner.
- Actual: CI sampled an almost neutral first frame in the off-screen snapshot even though the model had produced a valid three-colour palette.
- Errors: `ArtworkHeaderPresentationTests.swift` reported zero colour distance and insufficient chroma; 337 tests ran with 7 issues.
- First occurrence: main-branch 0.14.0 preflight run 33971166906 at commit `b258f1a`.

# Evidence

- The failing CI log showed three distinct palette values in the model while the rendered light snapshot contained three identical neutral pixels and the dark snapshot retained only 0.009 chroma.
- `FloatingRoomView` deliberately animates `roomArtworkPalette` over 1.1 seconds. The old test mounted the view before changing the model and captured after a fixed 180 ms, so the sampled frame depended on runner scheduling.
- The exact optimized CI command could pass locally without a source change, confirming a timing-dependent presentation test rather than a deterministic palette extraction or production rendering defect.
- SwiftUI's Reduce Motion environment value is read-only in the supported SDK, so the test cannot override it directly.

# Resolution

- root_cause: The snapshot test sampled an in-progress production animation at a fixed wall-clock delay. The GitHub runner captured close to the neutral starting frame while local scheduling often advanced farther through the transition.
- fix: Wait for each model state to settle, then mount a fresh real `FloatingRoomView` and `WalkieTalkieBar` for the snapshot. This preserves the production animation and all original colour, contrast, fallback, pause-retention, and Talk-bar assertions.
- verification: The focused optimized test passed 20 consecutive runs. The exact optimized release suite passed all 387 tests. `./Scripts/package.sh --arm64-only` produced an ARM64 ALO 0.14.0 build 81 app, ZIP, DMG, and CLI archive; local signature and package checks passed.
- files_changed: `Tests/ALOTests/ArtworkHeaderPresentationTests.swift`

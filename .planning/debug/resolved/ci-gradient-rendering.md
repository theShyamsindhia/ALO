---
status: resolved
trigger: "The 0.14.0 GitHub Actions build fails ArtworkHeaderPresentationTests while the same test passes locally; fix it and make the release good to publish."
created: 2026-09-05
updated: 2026-09-05
---

# Symptoms

- Expected: the album-derived multi-colour header renders in both light and dark appearance, and the release validation suite passes on the Apple Silicon GitHub runner.
- Actual: CI first sampled an almost neutral transition frame; after removing that timing dependency, its headless raster still attenuated absolute channel chroma even though it preserved full-width spatial variation and the model had produced a strong three-colour palette.
- Errors: the first preflight reported zero colour distance and insufficient chroma. The follow-up preserved the required spatial distances but failed only the raster's absolute chroma threshold.
- First occurrence: main-branch 0.14.0 preflight run 33971166906 at commit `b258f1a`.

# Evidence

- The failing CI log showed three distinct palette values in the model while the rendered light snapshot contained three identical neutral pixels and the dark snapshot retained only 0.009 chroma.
- `FloatingRoomView` deliberately animates `roomArtworkPalette` over 1.1 seconds. The old test mounted the view before changing the model and captured after a fixed 180 ms, so the sampled frame depended on runner scheduling.
- The exact optimized CI command could pass locally without a source change, confirming a timing-dependent presentation test rather than a deterministic palette extraction or production rendering defect.
- SwiftUI's Reduce Motion environment value is read-only in the supported SDK, so the test cannot override it directly.
- On the follow-up CI run, both rendered appearances passed the full-width colour-distance checks while absolute raster chroma was reduced to 0.006–0.009. The actual gradient stops retain calibrated chroma above 0.09; display-pipeline attenuation belongs to the raster layer, not palette validation.

# Resolution

- root_cause: The snapshot test mixed two environment-sensitive measurements: it sampled an in-progress 1.1-second production animation at a fixed wall-clock delay, then treated absolute chroma from a headless raster as the source palette's chroma. Runner scheduling and display processing therefore controlled the result.
- fix: Wait for each model state to settle, then mount a fresh real `FloatingRoomView` and `WalkieTalkieBar`. Validate colour strength on the calibrated gradient stops, while the rendered bitmap continues to prove full-width spatial variation, text contrast, neutral fallback, palette retention on pause, and the black Talk bar.
- verification: The first timing fix passed the focused optimized test 20 consecutive times and the exact local optimized release suite passed all 387 tests. `./Scripts/package.sh --arm64-only` produced an ARM64 ALO 0.14.0 build 81 app, ZIP, DMG, and CLI archive; local signature and package checks passed. A signed remote preflight remains the publication gate.
- files_changed: `Tests/ALOTests/ArtworkHeaderPresentationTests.swift`

# Notch integration validation

The original DynamicNotch feature engine is embedded as `ALONotchRuntime`.
The ALO master switch, every additional feature, and every home-page selection
start off. Saved choices survive master-off, but background services stop and
queued/restorable content is cleared. The runtime is constructed lazily on first
enable. Settings alone do not grant system permissions.

## Automated checks

- Original and adapted feature tests cover animation, geometry, settings persistence,
  fake system events, temporary database watchers, cancellation, downloads, and
  file conversion. Fixtures use temporary data and fake Contacts authorization.
- Native render tests cover the original settings, local timer, converter and ALO
  room surfaces. Resource tests require localized labels, images, sounds and the
  media adapter to resolve from the packaged resource bundle.
- An idle check enables the master with all features off and asserts no service is
  running. A full-suite sample used 0.022 seconds of process CPU over 2 seconds and
  added 64 KiB to peak RSS. This measures the test process and inert feature engine,
  not whole-app energy use or enabled camera/conversion workloads.
- Local release testing uses the repository's existing Swift test-entrypoint
  optimizer workaround. Release packaging retains normal optimization.

## Storage and packaging

The notch runtime resource bundle is approximately 4.7 MiB. The full reference
source tree, test fixtures, original onboarding assets, compiler caches and dSYM
files are not included in the installed app. Lottie and the original updater are
excluded. Release packaging preserves a separate dSYM and strips debug/local
symbols from the distributed executable while retaining exports and Swift
reflection metadata. Original license and provenance notices are packaged.

Final package measurement and CI results are recorded after verification.

## Hardware and environment limits

Tests with injected services establish lifecycle behavior, not access grants or
compatibility of private system interfaces on every macOS version. Real camera,
Bluetooth accessories, global Now Playing, Apple Clock, Mail/Messages, HUD keys,
Focus, lock screen, physical display changes and multi-Mac playback still need
validation on the target hardware when those features are enabled.

The local iOS build is blocked by this machine's Xcode 26.6 installation: its
IDESimulatorFoundation cannot load a symbol from the installed DVTDownloads
framework. This is an environment failure before application compilation. The
repository's CI uses pinned Xcode 26.3 and runs an unsigned iOS simulator build.

No installed production app is replaced by these checks.

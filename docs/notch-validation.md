# Notch integration validation

The original DynamicNotch feature engine is embedded as `ALONotchRuntime`.
The ALO master switch, every additional feature, and every home-page selection
start off. Saved choices survive master-off, but background services stop and
queued/restorable content is cleared. The runtime is constructed lazily on first
enable. Settings alone do not grant system permissions.

## Automated checks

Release checkpoint before the visual correction: **255 XCTest feature tests + 757 Swift Testing tests
in 125 suites = 1,012 passing tests**, with no failures. The latter includes ALO’s
room, networking, UI layout and newly merged DJ Studio regression tests.


- Original and adapted feature tests cover animation, geometry, settings persistence,
  fake system events, temporary database watchers, cancellation, downloads, and
  file conversion. Fixtures use temporary data and fake Contacts authorization.
- Native render tests cover the original settings, local timer, converter and ALO
  room surfaces. Resource tests require localized labels, images, sounds and the
  media adapter to resolve from the packaged resource bundle.
- An idle check enables the master with all features off and asserts no service is
  running. A final full-suite sample used 0.023 seconds of process CPU over 2 seconds with
  no increase in peak RSS. This measures the test process and inert feature engine,
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

Lyrics use 128-entry in-memory LRU caches per provider with no HTTP disk cache.
Artwork caching is limited to 64 images / 8 MiB; screenshot path history is released
on stop. Tray, temporary sharing and screenshot staging use ALO-specific directories
and do not share cleanup folders with DynamicNotch. Files intentionally copied into
the tray and conversion exports are user-owned storage and are retained until removed.

Optimized Apple Silicon development package: **37 MiB installed**, including **4.7 MiB notch resources** and approximately **13 MiB ALO icon resources**. The notch resource size excludes compiled feature code. Packaging, deep/strict signature validation and packaged CLI help pass. Main settings → Notch was verified through native accessibility with the master off. The UI control service repeatedly disconnected during further feature-page inspection; native view rendering provides the visual checks below. The test master toggle was restored to off. The final rebuilt development app was reopened and its main Settings → Notch tab visually verified with the master off. No production app was replaced.

The corrected main-settings and lock-screen local full run passes **270 XCTest + 787 Swift Testing tests in 132 suites (1,057 total)**. Focused state/cleanup checks pass, including cancelled lyrics retry and queued callback invalidation. One earlier secure-UDP validation timeout did not recur in either subsequent full run; timing limits were unchanged.

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

Full XCTest discovery on this machine emits Apple Contacts/CoreData initialization
errors. A debugger trace identified XCTest's `allSubclasses` enumeration loading
ContactsUI metadata, rather than an application resolver call. Isolated Mail (11)
and Messages watcher (8) tests pass without these errors and use denied fake resolvers.

The final visual correction removes the initial room-bar wrapper. The host uses the
original panel factory, hosting view, activity layout and hit rectangle. A separate
Room media opt-in supplies ALO metadata and supported playback commands to the
original player. Focused corrected-render/adapter/cleanup tests pass (20 XCTest
and 4 Swift Testing cases). Original player, battery, tray and island PNGs were
visually inspected; no custom room card remains.

CI on macOS 15 exposed a Swift isolated-deinitializer backdeployment crash in
Mail/Messages reader cleanup. Safe empty nonisolated destructors and task-aware
XCTest fixture lifetimes address it; background-release regressions cover this path.

Original full-screen lock artwork/lyrics and lock settings were rendered by a passing native test using a temporary defaults domain, fake paused track and bundled placeholder art. The settings preview intentionally enables the three options in its fixture; user defaults remain off. The original views and layout are used directly, without an actual lock or network request.

The final ownership audit also passes all **275 runtime XCTest checks plus the runtime-resource Swift test** locally. ARC-only owners used by native views have explicit nonisolated destructors to avoid the observed macOS 15 backdeployment failure; classes with substantive shutdown destructors retain that cleanup. Native dispatched/autorelease and root-replacement regressions exercise the affected ownership paths.

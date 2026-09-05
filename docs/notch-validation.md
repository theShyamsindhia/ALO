# Notch integration validation

The original DynamicNotch engine, activity views and settings are compiled as
`ALONotchRuntime`. ALO supplies host lifecycle and room playback data/commands.
The initial custom room-bar wrapper was removed.

## Automated verification

[macOS 15 / Xcode 26.3 CI on c25a18d](https://github.com/theShyamsindhia/ALO/actions/runs/33998201793)
passes **276 XCTest + 787 Swift Testing tests in 132 suites (1,063 total)**,
**7 room-scenario tests**, and the unsigned iOS simulator build. Scenarios cover
music/voice/chat restarts, interrupted delivery and partition recovery.

The subsequent main merge preserves the updated room-settings interface, lyrics and arena multiplayer.
Focused merged settings, activation, room-adapter, lyrics and arena checks pass locally.
Normal optimized development packaging and deep/strict signature verification pass.
Release tests retain the repository's existing test-entrypoint optimizer workaround;
packaging retains normal optimization.

Coverage includes original geometry, motion, settings, fake system events, temporary
database watchers, conversion, cancellation and default-off lifecycle. The automatic
activation regression enables the master once and changes feature preferences without
manually reconciling or restarting the runtime. Base and root settings publishers have
stable identity so those changes reach observers on older Combine versions.

Native callback and autorelease regressions cover the macOS 15 isolated-destructor
backdeployment failures found during CI. ARC-only native-view owners use explicit
nonisolated destructors; existing substantive shutdown destructors retain their cleanup.

## UI and lock-screen states

Main **Settings → Notch** was visually verified in the running development app with
the master off. The UI control service disconnected during some earlier inspections;
original-view native renders provide the feature-level visual checks.

Original player, battery, file tray, non-notch island, settings, timer and converter
views were rendered and inspected. The lock-screen settings and full artwork/lyrics
panel use the original views with a temporary defaults domain, fake paused track and
bundled placeholder art. Preview switches are intentionally enabled only in that
fixture; defaults for users remain off. No actual lock or network request is required
by these render tests.

Lock-screen tests cover no song, paused progress, missing artwork, missing/failed
lyrics, unlock cancellation, same-track retry, late results after shutdown, and queued
callbacks after invalidation. Ended sessions do not retain old artwork. The full-screen
lock player follows system Now Playing; room media is a separate original-player adapter.

## Storage and lifecycle

The optimized Apple Silicon development app occupies approximately **37 MiB**,
including **4.7 MiB notch resources** and **13 MiB ALO icon resources**. Resource size
excludes compiled feature code. Full reference source, compiler caches, dSYM files,
onboarding assets, Lottie and the upstream updater are excluded from the installed app.
Symbols remain outside the app; original license and provenance notices are packaged.

Master, feature and home-page switches start off. The runtime is lazy; master-off stops
services and clears queued/restorable content while retaining user choices. Camera and
system-stat sampling are visibility-controlled. An inert-engine test measured 0.023
seconds of process CPU over 2 seconds with no peak-RSS increase; this is not a whole-app
energy measurement or a measurement of enabled camera/conversion workloads.

Lyrics caches are bounded to 128 entries per provider without HTTP disk caching.
Artwork caching is limited to 64 images / 8 MiB. Screenshot history is released on stop.
Tray, sharing and screenshot staging use ALO-specific directories. User tray copies and
conversion exports remain until the user removes them.

## Validation limits

Injected-service tests do not establish permission grants or compatibility of private
macOS interfaces on every version. Actual camera, Bluetooth, global media, Apple Clock,
Mail/Messages, HUD keys, Focus, physical display changes, lock-screen presentation and
multi-Mac playback require target-hardware checks when enabled. The user's Mac was not
locked and no production app was replaced.

Local iOS building is blocked by an Xcode 26.6 simulator-framework installation error;
the pinned CI iOS build passes. Local full XCTest discovery also emits Apple Contacts
initialization errors; a debugger trace identified XCTest subclass discovery loading
ContactsUI metadata. Reader fixtures use temporary data and fake denied authorization.

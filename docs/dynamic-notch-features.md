# DynamicNotch source inventory and integration map

The original repository supplied at `/Users/zex/Desktop/Files/Refrence Repo/DynamicNotch-main/` was imported under `Vendor/DynamicNotch/` (unchanged import retained in commit `a6d26f7`). Original geometry, animation, transitions, window hosting and activity views are
compiled once from the vendor tree through `ALONotchRuntime`. ALO supplies metadata,
commands and master lifecycle. The initial large room-bar wrapper was removed.

**These feature modules are now compiled into ALO through `ALONotchRuntime`. All additional feature switches and home pages start disabled. Enable the notch first, then choose features in ALO Notch Settings. System integrations require their corresponding macOS permissions; presence in the settings does not grant access.**

All paths in the following tables are relative to `Vendor/DynamicNotch/DynamicNotch/`. A directory denotes the complete feature, including its models, views, content, services and event handlers where present. ALO adapters control service lifecycle, content routing and persisted settings around these original files.

## Notch presentation and motion

| Capability | Original sources | Available upstream settings | Integration notes |
| --- | --- | --- | --- |
| Physical notch and floating capsule | `Shared/UI/Shapes/NotchShape.swift`, `Shared/UI/Shapes/DynamicIslandShape.swift`, `Core/NotchEngine/` | `Features/Notch/Settings/NotchSettingsView.swift`: size, background and stroke | SwiftUI/AppKit; notch versus capsule depends on display geometry. Selected originals are compiled by ALO. |
| Spring transitions and content blur | `Core/NotchEngine/Models/NotchAnimationPreset.swift`, `Core/NotchEngine/Models/NotchTransitionMetrics.swift`, `Shared/UI/Modifiers/NotchTransitionModifier.swift`, `Shared/UI/Modifiers/BlurFadeModifier.swift`, `Shared/Extensions/extension+AnyTransition.swift` | `Features/Notch/Settings/AnimationSettingsView.swift` | Original engine coordination and feature views are compiled by ALONotchRuntime. |
| Display selection and placement | `Application/Windows/OverlayWindowLayout.swift`, `Core/NotchEngine/Models/NotchScreenSelection.swift`, `Core/NotchEngine/Models/NotchScreenSelectionPreferences.swift` | `Features/Notch/Settings/DisplaySettingsView.swift`: screen selection and display behavior | Selected window-layout original is compiled; additional upstream selection logic uses the ALO adapter. |
| Mouse/trackpad dismiss and restore | `Shared/UI/Modifiers/NotchMouseSwipeModifier.swift`, `NotchSwipeDismissModifier.swift`, `SwipeFeedbackMetrics.swift`, `ResizeAwareBlurModifier.swift` in the same directory | `Features/Notch/Settings/GesturesSettingsView.swift` | Configurable behavior; original tap and swipe defaults apply when an activity is enabled. |
| Activity arbitration | `Core/NotchEngine/Models/NotchContentRegistry.swift`, `NotchContentPriority.swift` in the same directory, `Features/Notch/NotchEventCoordinator.swift` | `Features/Notch/Settings/ActivityPrioritiesSettingsView.swift` | Intrinsic engine behavior; configurable priorities decide which enabled activity occupies the notch. |

## Media, files and useful home pages — opt-in

| Capability | Original source directory | Settings source and options | Runtime dependencies / validation notes |
| --- | --- | --- | --- |
| Now Playing controls | `Features/NowPlaying/` | `Settings/NowPlayingSettingsView.swift` within the feature: enable, favorite/output buttons, artwork 3D, progress tint, pause auto-hide and duration, source filter | Room playback retains ALO’s state and commands. The upstream system-wide monitor uses a bundled MediaRemote adapter, Perl helper and private MediaRemote framework. |
| Lyrics | `Features/NowPlaying/Services/Lyrics/` | Lyrics toggle in `Features/LockScreen/Settings/LockScreenSettingsView.swift` | Network providers `Provider/LRCLIBLyricsProvider.swift` and `Provider/OvhLyricsProvider.swift`; original track matching and presentation are retained. |
| Configurable home pages | `Features/HomePage/` | `Settings/HomePageSettingsView.swift`, `HomePagePagesSettingsView.swift`, `HomePageSettingsStore.swift` within the feature: enable, page order/visibility, scroll axis, indicator visibility/size | Uses the original content registry and visibility-controlled page lifecycle. |
| CPU and RAM graphs | `Features/SystemStats/` | Home-page visibility/order above; no dedicated settings view | Darwin/Mach sampling in `ViewModels/SystemStatsViewModel.swift`; start/stop monitoring with actual visibility. |
| Local countdown timer | `Features/Timer/` | `Settings/TimerSettingsView.swift`: enable, stroke, sound enable and sound choice | `ViewModels/LocalTimerViewModel.swift` is separate from Apple Clock monitoring. Local timer events and bundled sounds are connected. |
| Apple Clock timer mirror and controls | `Features/Timer/Services/ClockTimerMonitor.swift`, `ClockTimerController.swift` | Same timer settings | Accessibility-based control and system-log monitoring. Validate separately from local timers. |
| Camera preview | `Features/Camera/` | Home-page visibility and application camera permission UI | AVFoundation camera authorization; start capture only when feature is used. |
| Download progress | `Features/Download/` | `Settings/DownloadsSettingsView.swift`: enable, progress indicator style and stroke | Folder filesystem watcher; Chromium metadata reader uses SQLite. Requires access to monitored files/browser metadata. |
| File tray and AirDrop | `Features/DragAndDrop/` | `Settings/DragAndDropSettingsView.swift`, `FileTraySettingsView.swift`: enable, AirDrop/tray target, copy/move mode, scroll direction, remove button, AirDrop stroke | AppKit drag/drop, file operations and AirDrop controller; preserve originals under `AirDrop/`, `Tray/`, `Components/` and event handlers. |
| Image/audio/video/archive conversion | `Features/FileConverter/` | `Settings/FileConverterSettingsView.swift`: enable, formats, output location, filename collision handling, suffix, quality | ImageIO, AVFoundation, `/usr/bin/afconvert`, `ditto`, `tar` and `gzip`. `Models/FileConverterModels.swift` lists formats; actual encoder availability still needs runtime verification. |
| Screenshot preview and OCR | `Features/ScreenshotHub/` | `Features/ScreenRecording/Settings/ScreenCaptureSettingsView.swift`: enable, system-thumbnail behavior, auto-hide/duration, screenshot save folder | Filesystem screenshot watcher and Vision OCR. The explicit screenshot option can change system-thumbnail behavior; stopping the feature restores the previous preference. |
| Screen-recording indicator/results | `Features/ScreenRecording/` | `Settings/ScreenCaptureSettingsView.swift`, `ScreenRecordingSettingsStore.swift`: enable, style, stroke, recording save folder | System recording monitor and capture UI/process integration; verify actual macOS capture flow and permissions. |

## System events and notifications — opt-in

| Capability | Original source directory | Settings source and options | Runtime dependencies / validation notes |
| --- | --- | --- | --- |
| Charging / low / full battery | `Features/Battery/` | `Settings/BatterySettingsView.swift`, `BatterySettingsStore.swift`: individual enables, thresholds, durations, styles, stroke and sounds | IOKit power service; bundled sound assets. |
| Bluetooth accessory status/battery | `Features/Bluetooth/` | `Settings/BluetoothSettingsView.swift`: enable, duration, detail style, percent/ring indicator, stroke | CoreBluetooth/IOBluetooth and Bluetooth authorization; supported-device detection and battery readers. |
| Wi-Fi, no-internet and hotspot | `Features/WiFi/` | `Settings/WifiSettingsView.swift`: Wi-Fi alerts/duration, hotspot enable/style/stroke, network detail options | Network/interface monitoring; upstream includes a local-network usage description. |
| VPN state and connection page | `Features/VPN/` | `Settings/VpnSettingsView.swift`: preferred VPN; connectivity store also holds connect/disconnect alerts, durations and timer/detail options | System VPN status/control integration; test with actual configured VPN service. |
| Volume, brightness and keyboard HUD | `Features/HUD/`, `Core/SystemBridges/DisplayServicesBridge.swift` | `Features/HUD/Settings/HUDSettingsView.swift`, `HUDSettingsStore.swift`: per-HUD enable/duration, layout, bar/ring, tint, glow, stroke, volume feedback | Accessibility event interception, CoreAudio and private display services. Avoid intercepting keys before explicit feature activation. |
| Calendar events | `Features/Calendar/` | `Settings/CalendarSettingsView.swift`, `CalendarSettingsStore.swift`: enable, selected calendars, all-day, days ahead, notice lead time, time format, ongoing-event hiding, privacy and sound | EventKit calendar authorization. |
| Focus / Do Not Disturb | `Features/Focus/` | `Settings/FocusSettingsView.swift`: enable, auto-hide/duration, icon/detail style, stroke, Focus-off alerts/duration | Reads Focus assertions and system logs; real mode names/custom icons use Full Disk Access. |
| Apple Mail notifications | `Features/Notifications/AppleMail/`, `Features/Notifications/Shared/` | `Features/Notifications/Settings/AppleMailNotificationsSettingsView.swift`: enable and duration | Reads Mail database; explicit Full Disk Access flow. Preserve database reader/watcher and manager together. |
| Messages notifications and attachments | `Features/Notifications/Messages/`, `Features/Notifications/Shared/` | `Features/Notifications/Settings/MessagesNotificationsSettingsView.swift`: enable and duration | Messages SQLite/attachments require Full Disk Access; optional Contacts authorization resolves names/photos. Includes audio-message playback. |
| External-drive mount/eject notifications | `Features/Notifications/ExternalDrives/` | `Features/Notifications/Settings/ExternalDrivesNotificationsSettingsView.swift`: enable, duration, disk-image inclusion, ejection alerts | Workspace mount/unmount events; shared notification content and event handler. |
| Lock-screen media and transitions | `Features/LockScreen/` | `Settings/LockScreenSettingsView.swift`, `LockScreenFeatureSettingsStore.swift`: enable, sound/custom sounds, media panel, layout/material/tint/brightness, lyrics, expanded artwork and offset | Distributed lock monitor, overlay window levels and system bridge integration; private SkyLight-related code exists in `Core/SystemBridges/SkyLightOperator.swift`. |

## Shared dependencies included

- **Settings storage:** `Core/SettingsEngine/`, `Features/Settings/Shared/Stores/ConnectivitySettingsStore.swift`, `MediaAndFilesSettingsStore.swift`, plus individual feature stores. Upstream views reference these shared observable stores; a view copied alone is generally insufficient.
- **Settings UI:** `Features/Settings/Shared/Components/` contains reusable cards, rows, sliders, pickers, searchable/order lists and previews. `Features/Settings/Root/` provides the upstream navigation/catalog; ALO hosts the feature settings in its Notch Settings window.
- **Localization:** `Resources/Localization/L10n.swift`, `Localizable.xcstrings` and `InfoPlist.xcstrings`. Upstream README describes 38+ languages. Generated runtime localizations are loaded from the notch resource bundle.
- **Shared presentation:** `Shared/UI/Components/`, `Shared/Extensions/` and `Shared/UI/Environment/`; individual views use artwork, marquee, buttons and scale environment helpers.
- **Assets:** `Resources/Assets.xcassets/`, `Resources/Sounds/`, `Resources/LottieImage/`, plus feature-specific resources. Only runtime images and sounds are packaged; Lottie onboarding assets stay source-only.
- **Permission reference:** `Features/Settings/Application/Controllers/SettingsPermissionController.swift` and `Application/Info.plist` show upstream permission UI and usage descriptions. Configure ALO's own descriptions and prompts for activated features; source preservation grants no permissions.
- **Packages:** upstream Xcode package references are Lottie and Sparkle. Lottie supports vector animation assets. Sparkle belongs to the upstream update mechanism and is not needed for notch motion.
- **Global media adapter:** `Resources/MediaRemoteAdapter/` contains the framework, Perl helper and its own `LICENSE`; its notices are included in the package.
- **Existing verification material:** `Vendor/DynamicNotch/DynamicNotchTests/` and `DynamicNotchUITests/` preserve tests for motion metrics, screen selection, feature state, readers and monitors. Selected regression tests are compiled in Tests/ALONotchRuntimeTests; hardware integration still needs the checks below.

## Provenance and license facts

The supplied upstream README identifies `jackson-storm/DynamicNotch`, SwiftUI/AppKit and a macOS 14.6 minimum. `Vendor/DynamicNotch/LICENSE` contains GNU General Public License version 3. The MediaRemoteAdapter directory has a separate license file. Keep original notices with copied files and record adaptations relative to the original import commit. This inventory records repository facts, not a legal compatibility determination for ALO's eventual distribution.

Do not adopt the upstream app entry point, bundle identity, branding or update feed simply because its source is present. In particular, `Application/Info.plist` contains DynamicNotch's Sparkle feed and public key; those identify the upstream product, not ALO.

## Hardware validation

Camera, calendar, Bluetooth, HUD, global media, Mail/Messages, Focus and lock-screen
features use the original platform integrations. Their lifecycle and injected-service
paths are tested; permission grants and private macOS interface behavior must be
validated on the actual target system when those features are enabled.

## Activation and lifecycle

Use **ALO → Settings… → Notch** (also available through **ALO → Notch Settings…**) or **Room settings → Interface → Notch → Notch settings…**.
The master switch starts no individual feature by default. All home pages must also
be selected explicitly. Feature toggles start/stop their services; master-off stops
all services and clears queued/restorable activity content without erasing choices.

The original standalone app entrypoint/updater, onboarding, donation screens and
Lottie dependency are not part of the compiled ALO app. ALO owns updates and process
lifecycle. Permissions are requested only by explicit feature use. Original settings
such as global source filtering apply to local Now Playing, while room media continues
to use ALO's room model.

See [validation](notch-validation.md) for test and package measurements. Tests with
simulated services establish lifecycle behavior, not permission grants or compatibility
of private macOS interfaces on every OS version.

Room media uses the original player layout with ALO-supported transport commands. Seeking, favorites and lyrics are not supplied by the room adapter; original system-player source filtering and pause auto-hide apply to system media. The upstream About page identifies the reused DynamicNotch project; ALO owns app support and updates.

## Lock-screen media states

In **ALO → Settings… → Notch → Lock Screen**, enable the media panel, Expanded artwork, and Lyrics individually to use the original full-screen artwork/lyrics presentation. Each starts off. The lock-screen player follows system Now Playing; Room media is a separate notch adapter.

| State | Behavior |
| --- | --- |
| No current track / playback session ends | Hide the media overlay and clear old artwork; the normal macOS lock screen remains. |
| Playing | Show the original player; expanded artwork and lyrics follow their individual settings. |
| Paused, session still present | Keep the player available; elapsed time stops advancing. |
| Artwork missing | Use the original music-symbol fallback. |
| Lyrics disabled, unavailable or failed | Playback remains usable; no old-track lyrics are retained. |
| Unlock, media panel off, or notch master off | Hide/release the overlay and deactivate lyrics; queued callbacks cannot recreate a disposed panel. |
| Relock after a cancelled lyrics request | Allow the current track to request lyrics again. |

Automated checks use injected lock/media states; they do not lock the user's Mac or establish compatibility with every macOS lock-screen implementation.

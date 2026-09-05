# DynamicNotch source inventory and integration map

The original repository supplied at `/Users/zex/Desktop/Files/Refrence Repo/DynamicNotch-main/` is preserved under `Vendor/DynamicNotch/`. The compiled selection of original geometry, animation, transition and window-layout files is under `Sources/ALO/DynamicNotch/`. ALO's integration supplies its own room/media content and settings around that selection.

**The additional feature modules listed below are available as source only. Their presence in Vendor does not enable them in ALO, start their monitors, grant permissions, or expose their upstream settings at runtime.** The tables describe what can be integrated subsequently, not a claim that those integrations are finished.

All paths in the following tables are relative to `Vendor/DynamicNotch/DynamicNotch/`. A directory denotes the complete feature, including its models, views, content, services and event handlers where present. Preserve those original files when activating a feature, then add an ALO adapter for service lifecycle, content routing and persisted settings.

## Notch presentation and motion

| Capability | Original sources | Available upstream settings | Integration notes |
| --- | --- | --- | --- |
| Physical notch and floating capsule | `Shared/UI/Shapes/NotchShape.swift`, `Shared/UI/Shapes/DynamicIslandShape.swift`, `Core/NotchEngine/` | `Features/Notch/Settings/NotchSettingsView.swift`: size, background and stroke | SwiftUI/AppKit; notch versus capsule depends on display geometry. Selected originals are compiled by ALO. |
| Spring transitions and content blur | `Core/NotchEngine/Models/NotchAnimationPreset.swift`, `Core/NotchEngine/Models/NotchTransitionMetrics.swift`, `Shared/UI/Modifiers/NotchTransitionModifier.swift`, `Shared/UI/Modifiers/BlurFadeModifier.swift`, `Shared/Extensions/extension+AnyTransition.swift` | `Features/Notch/Settings/AnimationSettingsView.swift` | Selected originals are compiled by ALO; upstream engine coordination remains in Vendor. |
| Display selection and placement | `Application/Windows/OverlayWindowLayout.swift`, `Core/NotchEngine/Models/NotchScreenSelection.swift`, `Core/NotchEngine/Models/NotchScreenSelectionPreferences.swift` | `Features/Notch/Settings/DisplaySettingsView.swift`: screen selection and display behavior | Selected window-layout original is compiled; additional upstream selection logic requires ALO integration. |
| Mouse/trackpad dismiss and restore | `Shared/UI/Modifiers/NotchMouseSwipeModifier.swift`, `NotchSwipeDismissModifier.swift`, `SwipeFeedbackMetrics.swift`, `ResizeAwareBlurModifier.swift` in the same directory | `Features/Notch/Settings/GesturesSettingsView.swift` | Source only; needs event routing and state coordination with ALO's overlay. |
| Activity arbitration | `Core/NotchEngine/Models/NotchContentRegistry.swift`, `NotchContentPriority.swift` in the same directory, `Features/Notch/NotchEventCoordinator.swift` | `Features/Notch/Settings/ActivityPrioritiesSettingsView.swift` | Source only; decides which activity occupies the notch when several are active. |

## Media, files and useful home pages — source only

| Capability | Original source directory | Settings source and options | Dependencies / integration work |
| --- | --- | --- | --- |
| Now Playing controls | `Features/NowPlaying/` | `Settings/NowPlayingSettingsView.swift` within the feature: enable, favorite/output buttons, artwork 3D, progress tint, pause auto-hide and duration, source filter | ALO can supply its own playback state and commands. The upstream system-wide monitor uses a bundled MediaRemote adapter, Perl helper and private MediaRemote framework. |
| Lyrics | `Features/NowPlaying/Services/Lyrics/` | Lyrics toggle in `Features/LockScreen/Settings/LockScreenSettingsView.swift` | Network providers `Provider/LRCLIBLyricsProvider.swift` and `Provider/OvhLyricsProvider.swift`; track matching and presentation needed. |
| Configurable home pages | `Features/HomePage/` | `Settings/HomePageSettingsView.swift`, `HomePagePagesSettingsView.swift`, `HomePageSettingsStore.swift` within the feature: enable, page order/visibility, scroll axis, indicator visibility/size | Requires notch content registry and page lifecycle. |
| CPU and RAM graphs | `Features/SystemStats/` | Home-page visibility/order above; no dedicated settings view | Darwin/Mach sampling in `ViewModels/SystemStatsViewModel.swift`; start/stop monitoring with actual visibility. |
| Local countdown timer | `Features/Timer/` | `Settings/TimerSettingsView.swift`: enable, stroke, sound enable and sound choice | `ViewModels/LocalTimerViewModel.swift` is separate from Apple Clock monitoring. Wire local timer events and sound resources. |
| Apple Clock timer mirror and controls | `Features/Timer/Services/ClockTimerMonitor.swift`, `ClockTimerController.swift` | Same timer settings | Accessibility-based control and system-log monitoring. Validate separately from local timers. |
| Camera preview | `Features/Camera/` | Home-page visibility and application camera permission UI | AVFoundation camera authorization; start capture only when feature is used. |
| Download progress | `Features/Download/` | `Settings/DownloadsSettingsView.swift`: enable, progress indicator style and stroke | Folder filesystem watcher; Chromium metadata reader uses SQLite. Requires access to monitored files/browser metadata. |
| File tray and AirDrop | `Features/DragAndDrop/` | `Settings/DragAndDropSettingsView.swift`, `FileTraySettingsView.swift`: enable, AirDrop/tray target, copy/move mode, scroll direction, remove button, AirDrop stroke | AppKit drag/drop, file operations and AirDrop controller; preserve originals under `AirDrop/`, `Tray/`, `Components/` and event handlers. |
| Image/audio/video/archive conversion | `Features/FileConverter/` | `Settings/FileConverterSettingsView.swift`: enable, formats, output location, filename collision handling, suffix, quality | ImageIO, AVFoundation, `/usr/bin/afconvert`, `ditto`, `tar` and `gzip`. `Models/FileConverterModels.swift` lists formats; actual encoder availability still needs runtime verification. |
| Screenshot preview and OCR | `Features/ScreenshotHub/` | `Features/ScreenRecording/Settings/ScreenCaptureSettingsView.swift`: enable, system-thumbnail behavior, auto-hide/duration, screenshot save folder | Filesystem screenshot watcher and Vision OCR. Upstream settings can change system screenshot behavior; wire this as an intentional user action. |
| Screen-recording indicator/results | `Features/ScreenRecording/` | `Settings/ScreenCaptureSettingsView.swift`, `ScreenRecordingSettingsStore.swift`: enable, style, stroke, recording save folder | System recording monitor and capture UI/process integration; verify actual macOS capture flow and permissions. |

## System events and notifications — source only

| Capability | Original source directory | Settings source and options | Dependencies / integration work |
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

## Shared dependencies to retain when activating modules

- **Settings storage:** `Core/SettingsEngine/`, `Features/Settings/Shared/Stores/ConnectivitySettingsStore.swift`, `MediaAndFilesSettingsStore.swift`, plus individual feature stores. Upstream views reference these shared observable stores; a view copied alone is generally insufficient.
- **Settings UI:** `Features/Settings/Shared/Components/` contains reusable cards, rows, sliders, pickers, searchable/order lists and previews. `Features/Settings/Root/` provides the upstream navigation/catalog; ALO does not need a second application settings root merely to use a feature.
- **Localization:** `Resources/Localization/L10n.swift`, `Localizable.xcstrings` and `InfoPlist.xcstrings`. Upstream README describes 38+ languages. Import resource membership and lookup behavior with any views that depend on localization.
- **Shared presentation:** `Shared/UI/Components/`, `Shared/Extensions/` and `Shared/UI/Environment/`; individual views use artwork, marquee, buttons and scale environment helpers.
- **Assets:** `Resources/Assets.xcassets/`, `Resources/Sounds/`, `Resources/LottieImage/`, plus feature-specific resources. Copy only runtime assets actually needed into ALO's resource bundle.
- **Permission reference:** `Features/Settings/Application/Controllers/SettingsPermissionController.swift` and `Application/Info.plist` show upstream permission UI and usage descriptions. Configure ALO's own descriptions and prompts for activated features; source preservation grants no permissions.
- **Packages:** upstream Xcode package references are Lottie and Sparkle. Lottie supports vector animation assets. Sparkle belongs to the upstream update mechanism and is not needed for notch motion.
- **Global media adapter:** `Resources/MediaRemoteAdapter/` contains the framework, Perl helper and its own `LICENSE`; preserve those notices if that integration is activated.
- **Existing verification material:** `Vendor/DynamicNotch/DynamicNotchTests/` and `DynamicNotchUITests/` preserve tests for motion metrics, screen selection, feature state, readers and monitors. These are available reference tests, not evidence that every feature has been tested inside ALO.

## Provenance and license facts

The supplied upstream README identifies `jackson-storm/DynamicNotch`, SwiftUI/AppKit and a macOS 14.6 minimum. `Vendor/DynamicNotch/LICENSE` contains GNU General Public License version 3. The MediaRemoteAdapter directory has a separate license file. Keep original notices with copied files and record adaptations outside the unchanged snapshot. This inventory records repository facts, not a legal compatibility determination for ALO's eventual distribution.

Do not adopt the upstream app entry point, bundle identity, branding or update feed simply because its source is present. In particular, `Application/Info.plist` contains DynamicNotch's Sparkle feed and public key; those identify the upstream product, not ALO.

## Suggested follow-on todo list

- [ ] Choose the next runtime module from this inventory and define its ALO-facing behavior/settings.
- [ ] Reuse its original source files and required shared dependencies; keep the vendor snapshot unchanged.
- [ ] Connect ALO state, service start/stop, activity priority and settings persistence.
- [ ] Add actual required resources, framework links and permission descriptions for that module.
- [ ] Exercise the feature against real system events and confirm disabling it stops monitoring.
- [ ] Document runtime status separately from source availability; do not present inactive modules as functioning settings.

Low-dependency candidates are local timers, CPU/RAM graphs, battery and external-drive notifications. File tray/conversion add useful file workflows. Camera, calendar, Bluetooth, HUD, global media, Mail/Messages, Focus and lock-screen integration each need dedicated permission/system-behavior validation.

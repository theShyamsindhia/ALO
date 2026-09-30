# UI: bring every surface up to ALO style

Status: **parked**. This captures the UI audit so the work can be picked up later.
Nothing in the app has changed yet.

The audit was a static read of the source at `3c5c2e1` (v0.17.1 plus the updater merge).
Line numbers refer to that commit and will drift. No app was run and no renders were inspected,
so every tier below should be confirmed against CI's `alo-ui-renders` artifact before work starts.

## The problem in one paragraph

ALO has a real visual language, but only the "live channel" surfaces use it: the menu-bar
disc and popover, the floating room bar, the talk bar, the network browser shell, the video
viewer and the permission overlays. Almost everything a person touches *before* and *around*
listening is stock SwiftUI or AppKit. That covers identity setup, recovery, creating and joining
networks, members, invitations, channel creation, settings, file transfers, update results
and the whole iOS app. Those screens show raw IDs, raw errors, tiny fixed fonts and default
alerts. The result feels like a polished player bolted onto a developer tool.

## What "ALO style" already means

Derive the system from what exists; do not invent a new one.

| Source | What it defines |
| --- | --- |
| Brand guide (`docs/brand/README.md`) | Blue `alo` lettering with a **coral** terminal on a pearl tile. Uppercase **ALO** in copy. |
| Approved Figma (`docs/plans/native-conversation-ui.md`) | Glass sidebar, 8 pt inset content surface, 28 pt inner and 34 pt outer corners, system materials and semantic colours that adapt light to dark. |
| `ALONetworkTypography` / `ALONativeNetworkLayout` (`Sources/ALONetworkUI/NetworkBrowserViews.swift:5`) | Type ramp 22 / 17 / 14 / 11 pt; sidebar 210–280 pt; radii 34 / 28. |
| `Palette` (`Sources/ALO/GUI.swift:7382`, private) | Semantic ink/secondary/muted, adaptive control blue, voice blue, glass highlight, stroke, soft accent, video black. Two tokens have high-contrast variants. |
| `AdaptiveSurface` (`GUI.swift:7332`) | Rounded continuous glass card with strong stroke and inner highlight; opaque when Reduce Transparency is on. |
| `ArtworkHeaderBackground`, `AmbientBackground` | Now-playing artwork drives an accent and a blurred ambient backdrop. |

Gaps in the existing language:

- **Coral is in the brand but nowhere in the UI palette.** Decide its role (suggested: live/broadcasting and "you" highlights), or drop it from the brand.
- **`Palette` is private to one file** and disagrees with `ALONetworkTypography`: GUI body text is 9–11 pt, network UI body is 14 pt.
- **Three accent systems** compete in one window: fixed `Palette.controlAccent` blue, system `.accentColor`, and the artwork accent. The artwork accent has no contrast check (`calibratedHex`, `GUI.swift:7588`).
- **Forced-dark islands**: talk bar (`GUI.swift:6326`), What's New (`UpdatePresentation.swift:67`), DJ Studio, Breach. Everything else adapts.
- **Increase Contrast is effectively ignored** (no `colorSchemeContrast`; 2 of ~30 tokens have variants). Reduce Transparency is handled in 3 places. Reduce Motion is handled well.

Measured spread in `Sources/ALO`, `Sources/ALONetworkUI` and `iOS`:

| Measure | Count |
| --- | --- |
| Distinct literal font sizes | 28 |
| Literal font sizes of 9 or 10 pt | 116 |
| Uses of `@ScaledMetric` / `relativeTo:` | 3 |
| Distinct corner radii | 25 |
| Distinct padding values | 31 |
| Hard-coded RGB colours | 129 |

## Surface inventory

Tiers: **A** ALO style · **A\*** designed, but in its own language · **B** partial · **C** bare/stock · **X** dead or unreachable.

### Before listening: identity, networks, members

| Surface | File | Tier | What's bare |
| --- | --- | --- | --- |
| Identity setup ("What should we call you?") | `ALONetworkUI/IdentitySetupView.swift:10` | C | "ALO" as plain `.title3` text on a material card; stock field and button; no brand mark or backdrop. |
| Recovery key save | `IdentitySetupView.swift:156`, panel `MacNetworkSetupView.swift:404` | C | Plain warning label; stock save panel defaulting to Downloads. |
| Recovery key restore | `IdentitySetupView.swift:115` | C | Raw monospaced paste box; open panel accepts `.data` with no message. |
| Export recovery / share public identity | `MacNetworkSetupView.swift:404`, `:432` | C | Untitled save panels; file named `ALO-public-identity.json`. |
| Network browser shell and sidebar | `NetworkBrowserViews.swift:66`, `:507` | A | Identity avatar is a first initial only. |
| Nearby networks, requests row | `NetworkBrowserViews.swift:625`, `:602` | A | — |
| Join request review sheet | `NetworkBrowserViews.swift:693` | C | Plain sheet with a raw 76-character fingerprint. |
| Fingerprint sheet | `NetworkBrowserViews.swift:709` | C | Name, hex string, Done. |
| Create network | `ALONetworkUI/NetworkForms.swift:3` | C | Stock grouped Form in a fixed 600×520 sheet; Cancel as a Form row. |
| Import invitation | `NetworkForms.swift:72` | C | Grouped Form with a raw paste box. |
| Trust owner / add / remove member alerts | `MacNetworkSetupView.swift:51`, `:105-122` | C | Default alert showing the raw `alo-user-v1:<64 hex>` ID. |
| Add member (invite) | `ALONetworkUI/MemberInvitationView.swift:3` | C | Pasted JSON in, invitation dumped as monospaced JSON out. |
| Create channel + private member picker | `ALONetworkUI/CreateChannelView.swift:3` | C | Members shown as "Member <last 8 of ID>" with the full fingerprint. |
| Members sheet | `MacNetworkSetupView.swift:336` | C | List titled "Owner"/"Member" with the raw user ID; no names. |
| Empty: no networks | `NetworkBrowserViews.swift:594` | B | Callout text and a borderless link. |
| Empty: nobody nearby | `NetworkBrowserViews.swift:646` | C | Guidance only in a tooltip. |
| Empty: no channels (Mac) | — | C | **Missing.** Only the iOS-only `ALOChannelList` has one. |

### In a channel

| Surface | File | Tier | What's bare |
| --- | --- | --- | --- |
| Conversation, main window | `MacNetworkSetupView.swift:219` → `RoomChatPanel.swift:9` | A | Accent hard-coded `.blue` (`:221`), not the artwork accent. |
| Conversation: choose a channel | `MacNetworkSetupView.swift:241` | B | Stock `ContentUnavailableView`. |
| Conversation: opening | `MacNetworkSetupView.swift:233` | C | Bare `ProgressView("Opening channel…")`. |
| Conversation: failed | `MacNetworkSetupView.swift:246` | C | One grey text line, no icon, no retry. |
| Chat "…" menu and History popover | `RoomChatPanel.swift:258`, `:289` | C | Paragraphs of protocol text inside a menu and a fixed 11 pt popover. |
| "Message not sent" alert | `RoomChatPanel.swift:206` | C | Default alert. |
| Menu-bar disc, popover, pinned controls | `GUI.swift:149`, `:1113`, `MenuBarControls.swift:180` | A | — |
| Floating room bar, message strip, queue | `GUI.swift:4726`, `:5047`, `:5085` | A | 9–10 pt status and notice text. |
| "…" more controls popover | `GUI.swift:4779` | B | Plain 12 pt buttons, stock checkbox. |
| Floating chat panel | `GUI.swift:5236` | B | Body uses fixed 9–12 pt and a different type scale from the main window. |
| People / mixer | `GUI.swift:5487` | A | 9–10 pt labels; plain "Waiting for listeners…". Mute icon shows state on the slider and action on the button in the same row (`:5621` vs `:5645`). |
| Participant info popover | `GUI.swift:5714` | B | Stock headline, "ROOM ACTIVITY" caption. |
| Talk bar | `GUI.swift:6288` | A | Forced dark; 7 pt unread badge. |
| Talk target context menu, send file | `GUI.swift:6132` | C | Stock menu and open panel. |
| In-channel settings popover | `RoomPreferencesView.swift:4` | C | Stock pickers, toggles and disclosure groups at fixed 12 pt; jargon tooltips. |
| Microphone test, About popover | `MicrophoneTest.swift:123`, `RoomPreferencesView.swift:446` | C | Stock. |
| Video in bar, video window | `GUI.swift:5790`, `:6919` | A | — |
| Annotation tools, sticker picker | `AnnotationSceneView.swift:592`, `:697` | B / C | Stock pickers and menus in a material container. |
| Received media window | `SharedMediaWindow.swift:149` | B | Raw `localizedDescription` in red. |
| File transfers panel | `DirectFileSharingController.swift:366` | C | Titled NSPanel, stock buttons, `.white.opacity(0.05)` card invisible in light mode, raw errors. |
| Screen recording overlays | `GUI.swift:4460`, `:5833` | A | — |
| Microphone permission | `GUI.swift:3132` | C | Blocking NSAlert. |

### App-level

| Surface | File | Tier | What's bare |
| --- | --- | --- | --- |
| Settings window + tab picker | `AppSettings.swift:314` | C | Plain titled window with a segmented picker. |
| Settings → Appearance | `AppSettings.swift:396` | B | Custom icon grid, system accent. |
| Settings → Notch | `AppSettings.swift:377` | C | Stub that closes the window and redirects. |
| Settings → Device messaging | `DeviceMessagingSettingsView.swift:8` | C | Worst surface: UUIDs, TLS keys, shell commands. |
| What's New / update window | `UpdatePresentation.swift:53` | B | Forced dark, system accent, raw install error. |
| Check-for-updates results | `GUI.swift:1104` | C | NSAlert with raw `localizedDescription`. |
| App menus, About panel | `GUI.swift:983`, `:990` | C | No Window/Help menus; standard About with no credits. |
| Diagnostics | `Diagnostics.swift:735` | B | Custom cards, system tint. |
| Shortcut Mapper | `GlobalShortcuts.swift:397` | C | Clean but fully stock. |
| Touch Bar | `RoomTouchBar.swift:60` | C | Stock buttons. |
| Notch player / workspace / canvas / settings | `ALONotch.swift:25`, `ALONotchRoomWorkspace.swift:40`, `NotchRoomCanvas.swift:20`, `ALONotchFeatureBridge.swift:259` | A\* / B | Vendor language; stock pickers and dialogs inside. |
| Smoking log (popover, history, sheets) | `SmokingLogViews.swift` | C | Stock throughout. Also out of scope; see decisions. |
| DJ Studio + sheets | `DJStudioView.swift:6` | B / C | Own dark card language, hard-coded cyan/purple, wall-of-text guide, raw error alert. |
| Game library | `GameLibrary.swift:199` | A\* | Own palette, 8–10 pt labels, raw download errors. |
| Rift Arena / Stick Fight / Breach | `ArenaView.swift`, `StickFightView.swift`, `BreachGame.swift` | B / A\* | Mixed stock controls and custom HUDs. |
| Lyrics | `LyricsPanel.swift:105` | B | 9 pt line. |
| iOS app | `iOS/ALOApp/ContentView.swift` | C | Entirely stock List/Form; no ALO language. |

### Dead or unreachable UI

| Surface | File | Note |
| --- | --- | --- |
| Customize-this-Mac profile editor | `GUI.swift:1549` | Fully A-styled, but `editDeviceIdentity()` (`:3156`) has no caller. **Wire it up rather than delete it.** |
| `ALOView` progress / error cards | `GUI.swift:4424-4505` | Only reachable before identity setup. The Mac conversation error state should reuse this design. |
| `SetupBackground` slideshow | `GUI.swift:7173` | Never used, but `Scripts/package.sh:222` still ships the 5 images. The slides appear to be third-party art with no licence: one is a mockup of another site, one is signed "kunomori". Remove them. |
| Old floating composer / bubble | `GUI.swift:5361`, `:5424` | Delete. |
| In-popover games view | `GUI.swift:5252` | Delete. |
| Fourfold | `GameLibrary.swift:261` | Filtered out; finish or remove. |

## Recurring bare patterns to eliminate

1. **Raw errors shown to people.** `NetworkAccountModel.swift:528` interpolates the Swift error; also `AppUpdater.swift:180`, `DirectFileSharingController.swift:103`, `DJAudio.swift:578`, `SharedMediaWindow.swift:98`.
2. **Identifiers as primary content.** User IDs, UUIDs, fingerprints, TLS keys, JSON and CLI commands appear where names should. `MacNetworkSetupView.swift:343`, `:364`; `CreateChannelView.swift:74`; `MemberInvitationView.swift:69`.
3. **Stock grouped Forms as whole screens** in a fixed 600×520 sheet (`MacNetworkSetupView.swift:49`).
4. **Blocking NSAlert** for information and permissions (`GUI.swift:1105`, `:3134`, `SmokingLogViews.swift:30`).
5. **Fixed 7–10 pt text** that ignores the type ramp and the system text size.
6. **Ad-hoc colours** instead of tokens (`accent: .blue`, `Color.accentColor`, private game/DJ palettes, `.white.opacity` cards).
7. **Walls of protocol text** in menus, popovers and tooltips.
8. **Loading, error and empty states with no recovery action.**
9. **Stock open/save panels** with no title, message or friendly filename.

## Plan

### Phase 0: foundation (one PR, no visual change intended)

- Create a shared style module, e.g. `ALOStyle`, usable by the Mac app, `ALONetworkUI` and iOS.
- Move `Palette`, `AdaptiveSurface` and the artwork-accent logic out of `GUI.swift` into it.
- One type ramp based on `ALONetworkTypography`, built on text styles or `@ScaledMetric` so it follows the system text size. Set a floor of 11 pt for any readable text.
- Radius and spacing scales: pick about 5 radii and about 6 spacing steps from the Figma values and map every literal to one.
- One accent rule: artwork accent when media is playing, contrast-checked against the surface in light, dark and high contrast; ALO blue otherwise. Give coral a defined job.
- High-contrast variants for every token, and `colorSchemeContrast` handling on strokes and fills.
- Components: `ALOSheet` (header, body, primary/secondary actions), `ALOStateView` (loading, empty, error with retry), `ALOPersonChip` (avatar, name, optional verified short code), `ALOConfirm` (in-style replacement for NSAlert/`.alert`), `ALOErrorText` (maps errors to plain-language messages with a "Details" disclosure).
- A lint check that fails on new `.system(size:` literals, raw RGB colours and `localizedDescription` in view code outside `ALOStyle`.

### Phase 1: the path to first listen

Onboarding, recovery, create/join network, invitation import, join-request review, members, create channel, and the conversation's opening/failed/empty states.

- Replace IDs with `ALOPersonChip`. Show a short comparison code instead of a 76-character fingerprint.
- Replace Forms with `ALOSheet`, sized to content.
- Add the missing Mac "no channels" state and a proper "nobody nearby" state with visible guidance.
- Reuse the `ALOView` error card design for the conversation failure state, with Retry and permission links.
- Wire up the existing profile editor from the identity menu.

### Phase 2: settings in one place

- One Settings window with a sidebar: General, Audio, Playback, Interface, Appearance, Notch, Shortcuts, Advanced.
- Move the in-channel popover's content there and keep the popover as quick toggles only, so microphone and source can be chosen before joining.
- Move device messaging behind a developer flag, or out of the product.

### Phase 3: transfers, updates, permissions

- File transfers panel, received media window, update results and What's New, microphone permission, and open/save panels.
- No NSAlert for information. Friendly titles, messages and filenames on every panel.
- What's New follows the system appearance and the ALO accent.

### Phase 4: in-channel polish

- Floating chat uses the same type scale as the main window.
- One mute icon rule everywhere: show state, and put the action in the label and tooltip.
- Fixed-width labels get truncation and hover help.
- Decide whether the talk bar stays forced dark. If yes, make it a deliberate "live" surface and apply the same to other live surfaces.

### Phase 5: side surfaces and iOS

- DJ Studio, games and notch workspace adopt the shared tokens where they sit inside ALO chrome. Game HUDs can keep their own art.
- iOS adopts `ALOStyle` for colours, type and person chips.

## Decisions needed before starting

1. **Coral's role** in the UI.
2. **Forced dark or adaptive** for live surfaces such as the talk bar and What's New.
3. **Smoking log and device messaging**: remove, hide behind a flag, or restyle. Restyling them first would be wasted work if they go.
4. **Dead UI**: confirm removal of the slides, old composer and games view, and Fourfold.
5. **Localization**: whether Phase 0 also moves strings to a string catalog. Doing it with the component work is cheaper than later.

## How to verify each phase

- The repo already renders native UI in tests when `ALO_UI_RENDER_DIR` / `ALO_NETWORKS_SNAPSHOT_DIR` are set, and CI uploads them as `alo-ui-renders`. Add a render for every surface touched, in light, dark and high contrast, at default and large text sizes.
- Check each surface with Reduce Transparency and Increase Contrast turned on.
- Before closing a phase, review the renders side by side with the Figma reference.

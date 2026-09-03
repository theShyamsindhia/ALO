---
status: resolved
trigger: "also comand + A doent let us select text, basically all the keyboard controols too"
created: 2026-09-03
updated: 2026-09-03
---

# Symptoms

- expected: A focused ALO text field supports standard macOS editing shortcuts, including Select All, Cut, Copy, Paste, Undo, and Redo.
- actual: Command-A does not select the field contents; the other standard keyboard editing controls are also unreliable.
- errors: No visible error.
- timeline: Present in v0.13.9.
- reproduction: Open an animated editor such as New Room, Room Chat, or Up Next, then immediately use a standard editing shortcut.

# Current Focus

- hypothesis: confirmed
- test: Verify every animated editor activates ALO and requests focus after mounting; assert the complete Edit menu selector map.
- expecting: Standard shortcuts route to the mounted field editor.
- next_action: none
- reasoning_checkpoint: The app has no keyboard event monitor; native first-responder routing remains the single command path.
- tdd_checkpoint: passing

# Evidence

- timestamp: 2026-09-03T13:00:00+05:30
  observation: GUI.swift manually constructs the main menu and is the only source of editing key equivalents.
- timestamp: 2026-09-03T13:00:00+05:30
  observation: Undo and Redo were wired to zero-argument UndoManager selectors instead of the standard undo: and redo: responder actions.
- timestamp: 2026-09-03T14:00:00+05:30
  observation: Chat focus was toggled while its animated TextField was still absent, so the request could be lost before the editor entered the responder chain.
- timestamp: 2026-09-03T14:00:00+05:30
  observation: The focused menu regression test and all 105 package tests pass.

# Eliminated

- hypothesis: A local or global NSEvent monitor consumes Command-key events.
  reason: No event monitors, keyDown overrides, performKeyEquivalent overrides, or SwiftUI key-press handlers exist in the app target.
- hypothesis: A custom shortcut dispatcher is required.
  reason: AppKit's first-responder actions correctly cover editing once the animated field is mounted and focused.

# Resolution

- root_cause: Animated fields requested focus before they existed in the view hierarchy, and Undo/Redo bypassed AppKit's standard responder selectors.
- fix: Activate ALO and defer focus by one main-loop turn when each editor appears; route the complete Edit menu through nil-target first-responder actions.
- verification: 105 Swift tests passed; arm64 v0.13.10 package built and passed strict code-signature verification.
- files_changed: Sources/WERAI/GUI.swift, Tests/WERAITests/MainMenuTests.swift, Resources/Info.plist

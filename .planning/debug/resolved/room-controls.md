---
status: resolved
trigger: "Incoming media mute silences personal media; Spaces does not toggle; black Talk bar with unclipped unread badge."
---

## Symptoms

Room mute should affect remote media only. Clicking the menu-bar item should hide/show Spaces when not live. The lower bar should be black, with a fully visible unread count.

## Current Focus

- hypothesis: Incoming mute reaches HostSession's local source return; the idle status action only orders the setup window front; the action dock clips the negative-offset badge.
- next_action: Publish 0.13.49 after signed build verification.

## Evidence

- MeshSession.setIncomingMediaMuted and broadcaster startup both call HostSession.setLocalPlaybackMuted with the incoming preference.
- HostSession already determines its own return mute from BroadcasterPlaybackMode to avoid duplicate source playback.
- ALOStatusMenuController calls openMainWindow outside the live phase, whose closure only makes the window key/front.
- WalkieTalkieBar.actionDock clips its children, including a badge offset 9 points above a 30-point button in a 40-point dock.
- Synced origin/main through 8cf69c7 before changes; no local edits were present.

## Verification

- Removed the incoming-mute route into HostSession; its source/fallback playback choice remains authoritative. Remote receiver mute is still restored on startup and changed immediately while listening.
- Native setup-window show/hide repeats preserve content, frame, and unfinished text.
- Native snapshots verify pure-black surfaces and full badge bounds in both appearances, in menu-bar and standalone presentations. Reinstating the old dock clip causes six expected badge-test failures; removing it passes.
- Full serial suite: 298 tests passed, including timing, private transport, recovery, chat, and native presentation (181.8 seconds).
- Investigation performed inline; no subagents requested. No installed app restart, live-room mutation, or physical multi-Mac listening test performed.

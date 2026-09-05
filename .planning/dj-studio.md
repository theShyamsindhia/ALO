# DJ Studio — feat/dj-studio

## Request and assumptions
Replace the duplicate People-header settings control with a launchpad icon; keep the bottom settings control. Open a dedicated, resizable native DJ window. User clarified that the song section must control the currently broadcast song. Provide its live metadata, progress, previous/play/pause/next controls using existing room permissions. Local file loading remains available for the two DJ decks. No copyrighted song is bundled.

## Todo
- [x] Inspect existing People UI, settings, audio capture, and room lifecycle.
- [x] Create an isolated feature branch from clean main.
- [x] Build two file-backed decks: play/pause, seek, cue, whole-track loop, tempo, three-band EQ, channel gain.
- [x] Add equal-power crossfade, master gain, output metering and stop-all.
- [x] Add 16 playable synthesized pads, keyboard shortcuts, custom sample import and pad gain.
- [x] Add currently broadcast song artwork, metadata, progress, and room transport controls.
- [x] Replace the People-header control and preserve bottom settings.
- [x] Add an explicit DJ mix audio source for both secure and legacy room broadcasting; never capture the app's entire output.
- [x] Cover audio math, deck lifecycle, source teardown, and native layout; compile and run relevant regressions.
- [x] Review rendered UI and document verified results and remaining limitations.

## Design
Dark native performance window, cyan deck A and violet deck B, center mixer, colored 4×4 pads. Song files stream from disk. Tempo sync matches user-entered BPM, not an inferred beat grid. Loops use beat lengths or manual In/Out regions and native PCM repetition. Sharing uses the existing room transport and synchronized local renderer. Settings remain in the main settings entry point.

## Explicit limits
No streaming-service/DRM track extraction, automatic beat analysis, hardware MIDI mapping, or separate headphone device routing in this version. Local files and imported short samples are the supported sources.


## Verification — completed
- `swift build` passed.
- `swift test --filter 'DJStudio|RoomControlsPresentation|BroadcasterPlaybackMode|SystemAudioTapCapture|ParticipantMediaControlPolicy|PlaybackProgress'` passed: 31 tests in 8 suites.
- Offline rendering verifies real deck output, equal-power fading, master mute, and broadcast PCM delivery while duplicate local output is muted. No test emitted audible audio.
- Native screenshot rendered and visually checked: `/tmp/alo-dj-snapshots/dj-studio.png`.
- Independent audio review identified engine configuration changes; added explicit stop/recovery and broadcast failure propagation.
- Leaving the room stops playback. Closing DJ Studio stops playback and its active broadcast. Source ownership prevents stale teardown from stopping a newer subscription.
- `git diff --check` passed. Changes remain on `feat/dj-studio`.

## Usage
Open People → grid icon. The Room Song card controls the current broadcast using existing source capabilities. Load local files on Deck A/B for mixing. Click pads or use their displayed keys; right-click to import or restore samples. Stop the current broadcast before selecting Share DJ mix.

## Remaining live validation and product limits
A physical two-Mac listening test and output-device hot-swap have not been performed. Tests validate rendered PCM and existing transport regressions, not live network/audio hardware behavior. Deck processing applies to loaded files; current room-song controls are previous/play/pause/next plus progress, subject to the source's capabilities. There is no automatic beat-grid sync, separate headphone routing, recording, or MIDI mapping. These should not be presented as supported features.


## Follow-up: performance controls and main delivery
- [x] Make scrubbing visible with a waveform, loading state, drag-to-seek, slider, and file drop support.
- [x] Add persisted, conflict-checked key assignments and a window-scoped keyboard handler that respects text fields and dialogs.
- [x] Replace the whole-track-only UI with explicit beat and In/Out loop controls.
- [x] Add an in-app Guide and a repository user guide.
- [x] Verify key dispatch, loop PCM repetition, waveform lifecycle, and native layout.
- [x] Run optimized Mac tests and inspect relevant CI configuration.
- [ ] Commit this feature, fast-forward main, push origin/main, and verify the remote commit.

- [x] Review storage and CPU: stream source files, avoid disk caches, cap PCM buffers, cancel stale waveform jobs, and stop idle engine/UI work.


## Final follow-up validation
- Optimized build passed with the CI test flags on local Xcode 26.6.
- Full optimized Mac suite: **747 tests in 122 suites passed** (131.779 seconds of test execution).
- Key mappings persist and reject conflicts; event handling respects text entry, modifiers, repeats, and other windows.
- Loops produce real repeated PCM beyond the source duration, including resume within a region; allocation limits and relay revocation are tested.
- Waveforms scan all source frames sequentially in a 4096-frame buffer, catching transients anywhere in a bin; replaced/closed-window analysis is cancelled.
- Native loaded-song/loop screenshot checked at `/tmp/alo-dj-snapshots/dj-studio.png`.

- The standalone scenario script initially ran Debug and hit the existing 3-second processing budget in a pending-document test. The identical optimized test passed in 0.773 seconds. Aligned the script with the existing CI release flags and serial execution; all fixture sizes, assertions, and timing limits remain unchanged. Added a guard against a zero-test success.

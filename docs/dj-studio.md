# DJ Studio guide

Open **People → grid icon**. **Keys** and **Guide** are in the DJ Studio header. The regular room settings remain in the bottom toolbar.

## Record the playing broadcast — no imported file needed

1. Start or join a room broadcast with music playing, then open DJ Studio.
2. Press the red **REC** beside deck A or B. It changes to **Stop** with an elapsed timer.
3. Press **Stop** when you have the section you want. Capture also stops automatically at 32 seconds.
4. On A, press **Play take** (or its Play key) to replace the live input with your recording. The live music keeps playing until you do this. On B, press **Play** and move the crossfader toward B to hear the take alongside A.
5. Use the recorded take's waveform, cue, tempo, EQ and Looper. You can return A to **Live broadcast** at any time.

Recording captures the original broadcast audio before this Mac's DJ effects and pads. It does not record voice chat or the microphone. An empty capture reports that no broadcast audio arrived. Only one deck records at a time; starting a new take replaces the prior take on that deck after capture succeeds.

While the live route is active, recorded decks follow incoming room playback. For independent local playback, select **Recorded / file** (or **Play decks locally** when A is already a recorded take). To broadcast an independent recorded mix, stop the existing source and use **Share DJ mix**. No source file import is required.

## Optionally load a song and find the scrubber

Click **Load song** on Deck A or B, or drop an audio file onto a deck. Below the title is **WAVEFORM / SCRUB**. The waveform is generated in the background with a visible loading indicator. Drag anywhere across it to seek; the slider immediately underneath is also a scrubber. The white line marks the playhead. Playback starts only when you press Play.

The **Room Song** card controls the currently broadcast song through previous, play/pause and next, when its source supports them. Its progress is read-only; the live deck has a separate rewind scrubber.

## Process the current live broadcast

Select **Live broadcast** above Deck A while a room broadcast is active. An existing broadcast is selected automatically when you open the studio. No audio file is needed. Live input starts at unity gain, neutral EQ and crossfader A so opening it does not change the existing sound. A records a rolling 32-second history in RAM; its waveform shows incoming audio. Drag the rewind slider to replay recent audio, or choose **Jump live** to return to the incoming stream. You cannot seek into audio that has not arrived or beyond the retained history.

The live looper repeats the most recent selected number of beats ending at the current rewind cursor. Enter the BPM, allow that much audio to arrive, then press Loop. In/Out lets you mark a custom region as the live stream advances. Cue saves a position within retained history. Old cues expire when the buffer rolls past them. Live tempo follows the stream; the BPM field determines loop length and does not time-stretch live audio.

**When you are broadcasting**, EQ, gain, crossfader, loops, rewind, Deck B and pads are mixed into the audio sent to the room. **When you are listening**, these controls affect only this Mac. Voice chat bypasses the DJ effects. The live Play control mutes/unmutes Deck A; Room Song transport still controls the source where supported. Switching away from live input or closing the window discards the history and restores normal room audio. A broadcaster or broadcast-epoch change also disables live input and clears the previous history. Processing follows incoming media packets; if the source stops sending audio, the loop and overlays pause with it.

## Use the looper

Each deck has a labeled **LOOPER** section below transport controls.

1. Enter the song's original BPM.
2. Choose **1, 2, 4, 8, or 16 beats**.
3. Move the scrubber to the start of the section, then press **Loop**. Press Play if the deck is paused.
4. **Exit loop** continues the song from the current position. **Clear** also removes the markers.

For a custom region, press **In**, play or scrub forward, and press **Out**. The selected region is highlighted on the waveform. Loops must fit inside the song and last between 0.02 and 32 seconds. Seeking outside an active region exits the loop. Changing the beat length resizes an active region from its start.

The audio player repeats a prepared PCM region directly, without waiting for a UI timer between repetitions. Loop lengths use the BPM you enter; ALO does not detect a beat grid or automatically choose a musical downbeat.

## Keyboard controls

Bindings work only while DJ Studio is the active window. Typing into fields and using sheets/dialogs suspends performance shortcuts. Held keys do not repeatedly trigger actions.

| Action | Default key |
| --- | --- |
| Pad row 1 | `1 2 3 4` |
| Pad row 2 | `Q W E R` |
| Pad row 3 | `A S D F` |
| Pad row 4 | `Z X C V` |
| Deck A / B record-stop | `U` / `I` |
| Deck A / B play-pause | `T` / `Y` |
| Deck A / B return to cue | `G` / `H` |
| Deck A / B toggle loop | `B` / `N` |
| Crossfader A / center / B | `J` / `K` / `L` |
| Stop all | `Esc` |

Open **Keys**, edit an assignment, and press **Apply** or Return. Each action needs a unique key. Reassign the existing owner first if a key is already used. Changes are saved across app launches. **Reset defaults** restores the table above. Pad labels and the in-app guide reflect your saved bindings.

## Mix and perform

- **Cue** returns to the saved cue; the flag button saves the current position.
- **Tempo** changes speed while preserving pitch. Click the percentage to reset. **Match tempo** matches the other deck using the BPMs you entered, within ±25%; it does not align beat phase.
- **Low / Mid / High** adjust EQ. Click a dB value to reset that band.
- **Gain** balances each deck; **Crossfader** blends A and B. **DJ Master** controls the complete deck-and-pad mix. Reduce gain if the output meter shows peaks.
- Click a pad or press its displayed key. Right-click to load a mono/stereo sample up to 10 seconds long, or restore its built-in sound. Pads play one-shot samples. The song looper is on each deck.

## Share with the room

Rehearse locally, stop any existing broadcast, then click **Share DJ mix**. Both decks and the launchpad use ALO's existing synchronized room audio path. The room renderer supplies the local copy to avoid doubled audio. **Stop sharing** ends the DJ broadcast.

**Stop all** stops both file decks and pads; in live mode it mutes the live deck and clears its loop. Closing DJ Studio also stops its broadcast; leaving a room stops playback. If your output device changes, playback stops and you can restart on the new output.

This version uses the Mac's current output. Separate headphone cue routing, hardware MIDI, automatic beat analysis, live overdub recording, and recording export are not implemented.


## Storage and performance

Song files stream from their original locations; DJ Studio does not duplicate them, download sound packs, or write a waveform cache. Only keyboard preferences are retained across normal app sessions. Explicit REC takes use temporary 16-bit WAV files, up to about 6.15 MB per deck; replacing/clearing a take, closing DJ Studio or leaving the room removes those files. Built-in pads are synthesized in memory (about 2.4 MB total). Each waveform contains at most 256 floating-point peaks; superseded analysis is cancelled.

Loop PCM is limited to 16 MiB per deck and released by Stop all or window close. Imported pads are capped at 10 seconds of stereo 48 kHz audio (about 3.7 MiB per pad), with a 16 MiB limit on the temporary source decode buffer. High-resolution inputs over that budget are rejected with a shorter-sample suggestion. Engine buffers and file decoding add their own memory overhead; these are per-buffer limits, not a claim about the entire app's RAM usage.

The engine initializes only when DJ Studio is used. UI updates run at 20 Hz while the window is open, avoid redundant idle-meter updates, and stop when it closes. The audio engine also stops when the window is closed and DJ sharing has ended. No broadcast PCM conversion buffer is allocated during file-only local rehearsal. Live processing is bypassed when disabled. Its dry history and loop together are capped at 12,288,000 PCM bytes (about 11.7 MiB), plus a 19,200-byte overlay queue and small waveform/filter state. These live buffers are released when live input is disabled. Arming REC adds a fixed 6,144,000-byte PCM buffer, released after finishing or cancelling capture; only an explicit REC action creates a temporary deck file.

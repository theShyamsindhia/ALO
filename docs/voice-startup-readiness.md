# Voice startup readiness

Secure voice starts capture only after the current immutable wire session has
validated sender return paths for **every** requested recipient. Receiver-active
is not sender readiness: it requires first PCM and would deadlock this startup.
The wait is bounded to eight seconds. Do not relax admission or buffer old
unauthorized speech to compensate for a slow handshake.

`DirectedVoiceSession.whenTransmissionReady` supplies the sender-only check.
`SecureMacVoiceBridge.waitUntilReady` binds it to capture ID, fresh wire ID, and
exact audience. `VoiceCaptureStartup` is the actual MeshSession call path:
announce, await readiness, revalidate intent, start capture, revalidate again.
Failed, timed-out, replaced, or cancelled startup retires the announced session.
Legacy voice retains its original startup order.

`VoiceCaptureLifecycle` distinguishes pending from ready. Explicit replacement
uses fresh IDs, so an old await cannot end a newer audience. Passive events may
continue an existing capture or an explicitly owned restart, never dormant
stored targets. Repeated departures preserve continuation for remaining targets;
terminal failure clears that authority. GUI phase updates are channel-generation
fenced. Keep these privacy and cleanup rules when changing startup.

Regression evidence: the unchanged extracted startup sequence produced
`[capture, began]` instead of `[began, capture]`. A real directed-voice harness
separately showed sequence 0 discarded before validation and sequence 1 delivered
after validation. The secure discard is correct; capture ordering was wrong.
After the fix, 29 focused tests across startup, intent, directed transport, and
route completion passed without microphone capture or hardware playback.

This addresses startup clipping, not a proven cause or fix for persistent
muffling, low volume, Bluetooth distortion, or media synchronization. Native
speech quality and broader integration require separate evidence. These tests
do not claim acoustic delivery.

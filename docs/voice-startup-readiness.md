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

The readiness review follow-up reproduced three failures in 15 focused tests:
timeout was indistinguishable from stale state, a publisher failure was lost,
and bridge cancellation exposed a transport error. After correction, 31 tests
across five suites passed. Timeout is now a bounded connection error; stale or
cancelled waits cancel startup, while publisher failures retain their cause.
Pending end, stop, and failure complete the readiness callback exactly once.

The bridge regression uses the actual `waitUntilReady` and startup helper with
an internal fixture supplying outgoing state and held readiness callbacks. It
checks capture stays inactive until success and rejects replaced wire, capture,
or audience identities. It does not exercise live Mesh publication, a real
microphone, or acoustic delivery. The stale-target restart branch also releases
only its own continuation token; it cannot authorize a dormant capture.

This addresses startup clipping, not a proven cause or fix for persistent
muffling, low volume, Bluetooth distortion, or media synchronization. Native
speech quality and broader integration require separate evidence. These tests
do not claim acoustic delivery.

The phase presentation follow-up reproduced eight runtime assertions across
five tests using the unchanged production mapping: automatic restart could leave
Connecting text after readiness, idle could claim Talk was off with remaining
targets or retain Connecting over incoming/Open Line status, and local Open Line
presence omitted its microphone state. The shared pure presentation boundary
now reports ready speech, paused selected targets, and other active voice status;
it does not authorize capture. The existing channel-generation fence remains in
the GUI. Phase callbacks are synchronous before startup errors are presented,
so failure messages retain precedence.

The corrected mapping passed 36 tests in six suites together with the readiness,
startup, intent, and route regressions. That run preceded mechanical removal of
an unused previous-status parameter; the next integrated build validates that
cleanup. These status tests use no microphone or playback and do not test a live
GUI window or acoustic behavior.

An Open Line can emit the real connecting phase before its new state reaches
the GUI: both invite and accept await capture reconciliation before publishing
the Open Line state callback. Therefore no GUI Talk targets does not mean no
wire audience. A follow-up regression reproduced one false "Talk is off" result;
the corrected generic "Connecting voice…" passed all five presentation tests.
It leaves Talk starting/talking flags unchanged and does not reorder publication.
The microphone-change notice is retained: subsequent truthful paused/connecting
status is acceptable, without adding separate presentation state. The duplicate
target intersection was consolidated mechanically.

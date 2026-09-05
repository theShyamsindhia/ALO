# Integrated nearby + screen annotations release

Status: full integration now targets **0.14.1/build 82**, not released. Latest published release is 0.14.0, independently published from8437bf0. Historical checkpoints below are append-only; see the latest runtime checkpoint for current verification.

## Current handoff — September 6

- User requested removal of obsolete drafts and an increment over the actual
  latest published release. Removed empty draft release records383084669(v0.13.48)
  and383079720(v0.13.47), preserving JSON metadata outside repo under
  `/Users/raj/.codex/alo-release-validation/deleted-draft-*.json`. No tags or
  published releases were deleted. Confirmed no draft releases remain.
- Origin/main36f6c08 merged. Version0.14.1/build82 committed/pushed45657ba on
  codex/full-nearby-integration; published0.14.0 notes preserved separately.
- Prior85336fe full670test local/CI failed only deterministic110ms capture
  stall274.816ms/250ms. b4db040 uses max recent service interval rather than mean;
  focused16testsPASS,110ms case236.928ms with54packets/min50. Fable closure
  review-interval-closure.log has no remaining actionable finding.
- However b4db040 full local run failed live terminal liveness: one congested
  peer's last sequence179 was below required183. Latest merged45657ba full
 716tests/117suites reproduced the same failure and also an apparent stale-ABI
  optional comparison (`nil == nil` reports false) after new remote model fields.
  Do not treat candidate as validated, weaken assertions, or rerun until lucky.
  Diagnose sender terminal-tail starvation and clean-build metadata ABI first.
- CurrentCI33984248986 running at checkpoint; iOS jobPASS, Mac jobpending.
  CurrentFable read-only review b4db040..45657ba in tmuxalo-0141-merge-review,
  logreview-0141-merge.log. It must be read fully before final review claims.
- No0.14.1release/tag/mainintegrationpush. No local signing or installed app/data
  changes. All three subagents are unavailable/idle after usage-limit errors;
  do not infer their tasks are still running. Source tree otherwise clean.

Requested sources: latest **Explain AirDrop in airplane mode** plan (5 September
2026) and **Design realtime screenshare UX** plan, plus the report that one M4
MacBook Pro joining disrupts audio throughout the room. Neither plan may be
claimed complete based only on isolated reducers or cryptographic primitives.

## Release gates

- Shared secure v2 runtime on Mac and iOS: per-installation TLS identities,
  explicit first-contact trust, known-key pinning, exporter-bound private-room
  admission, separate authorized room/media/video channels and authenticated
  receiver-initiated UDP return paths. No automatic legacy downgrade.
- Explicit saved-room migration and capability policy. Mobile is a full mesh
  participant, with no broadcasting/queue editing/shared playback control.
- Lifecycle-owned discovery; symmetric dialing/deterministic arbitration;
  authenticated peer directory; per-channel recovery and make-before-break
  cutover. Liveness expiration must not durably terminate broadcaster ownership.
- Current-timeline recovery, frame deduplication, fresh codec configuration/IDR,
  bounded media queues and 10 ms encrypted voice packetization.
- Actual iOS app target using shared networking/core and platform audio adapter,
  with consent-safe microphone, route changes, background playback/suspension,
  rejoin, independent level preferences and tested app linking.
- Canonical annotation commands/events/snapshots wired into admitted media
  transport, bounded queues, host monotonic expiry and per-actor replay ordering.
- Viewer/presenter overlay alignment, source-window tracking and capture
  exclusion, persistent tool selection, keyboard/accessibility controls,
  moderation and participant permission UI, shortcut integration and diagnostics.
- Regression reproduction/fix for disruptive late joins; existing audio,
  Automerge, voice, recovery and realistic room scenarios remain green.
- Unprivileged Mac test CI and iOS simulator build/test CI, independent review.
- Physical two-Mac/iPhone/iPad networking and audio/video/voice acceptance as
  required by the source plan. Simulations do not certify radio performance,
  acoustic synchronization, Bluetooth fidelity or production permission flows.

## Work started

- Bounded control-line parser (including unterminated tails), regression tests
  and disconnect on overflow.
- Late-join reproduction: rising RTT leaked through `outputLatencyFloor`, raising
  the whole room buffer 250 → 305 → 380 → 455 → 555 ms and commanding four healthy
  listener restarts. Hardware-only floor correction removes RTT from that field;
  network recommendations still include RTT. This reproduces a mechanism, not a
  confirmed hardware-specific diagnosis of the reported M4 Mac.
- Bounded per-listener encoded-video queue with IDR/configuration recovery,
  in-flight send deadline and independent legacy video path repair.
- Annotation authority/replica, capture metadata/geometry, reusable native scene,
  toolbar and nonactivating overlay controller.
- Secure datagram/admission/subscription primitives, connection supervisor and
  bounded-lifetime peer-to-peer discovery coordinator.

## Latest verified checkpoint

- Fetched and fast-forwarded upstream through `3d576f7` (v0.13.44); new chat and
  native Spaces UI changes merged without conflicts. Unreleased work was restored
  from retained safety stash `1b4bc607950f56890deaef68ab06bd25ce3315a3`.

- Actual mutual TLS and admitted room/media role dispatch are implemented. Secure
  full-mesh tests cover simultaneous joins, key/secret rejection, direct-edge
  repair after seed loss, newcomer expansion and expiring identity-bound hints.
- Receiver-initiated UDP now completes the actual return-path challenge/response
  and decrypts media. Tests exposed and fixed a new-transport bug where optional
  completion chaining skipped enqueueing when no callback was supplied. This was
  unreleased code, not a diagnosis of the installed app.
- Late-join RTT regression has both low-latency and above-default hardware cases.
  A further pause/resume allowance-loss regression was reproduced red then fixed.
  Fable high re-review found no actionable timing regressions. M4-specific causality
  remains unconfirmed; diagnostics now separate per-listener network recommendation,
  hardware floor, timing eligibility and report age, without exporting peer IDs.
- Latest focused run: 34 tests / 8 suites passed, including actual encrypted UDP
  join/leave/rejoin, unauthenticated noise isolation, lease expiry, secure mesh and
  the late-join timing cases. Earlier full-suite checkpoint: 297 tests passed;
  rerun the full suite after the newer integrations before release.
- `iOS/ALO.xcodeproj` now links successfully for arm64/x86_64 Simulator with
  CODE_SIGNING_ALLOWED=NO. It implements secure room discovery/admission, mesh chat,
  participants and read-only queue; it deliberately advertises chat only. Media
  and voice are explicitly unavailable until connected to the real runtime.
- Shared Apple audio code and pure lifecycle/scheduling tests exist; simulator
  compilation succeeds. Actual route/audio/microphone behavior is not yet tested
  on an iPhone/iPad.
- Annotation wire framing, bounded snapshot assembly and admitted host/viewer
  coordinators exist. Mac scene properties are not yet connected to those channels;
  do not advertise the annotation feature as working in the app.
- Full post-merge checkpoint passed 360 tests / 48 suites. The concurrent
  **Review systems SDKs and APIs** task is now fixing additional security,
  retention, lifecycle and transport review findings in this shared checkout;
  its newer changes still require a centralized full-suite run. Do not stash,
  commit, release, or start a competing compile until that task hands off.
- Annotation snapshot retry disconnect and reentrant event ordering bugs were
  reproduced in failing tests. Coalesced recovery and FIFO publication fixes are
  applied and passed the centralized 376-test checkpoint. A further source stop/
  restart during event delivery regression reproduced retired wire revisions
  `[1, 2]`; per-delivery source checks now discard those stale events. All 41
  annotation tests / 5 suites pass (`/tmp/alo-annotation-source-green.log`).
- An isolated unsigned iPhone simulator launched the app but exposed Keychain
  error -34018. The user approved an explicit Debug-simulator-only temporary
  identity harness. `--alo-temporary-simulator-identity` now selects in-memory
  keys, pins, credentials/history and a visible test-session banner, without
  local signing or touching production storage. Unsigned app rebuild succeeded;
  actual isolated simulator launch reaches Nearby with the test-session banner.
  Relaunch without the flag retains Keychain -34018 fail-closed behavior. No room
  was scanned/joined or microphone activated; the simulator was shut down after
  checking. Fable low checked isolation/lifecycle and prompted clearer consent
  about remote peers retaining identity pins/records/messages. Use isolated test
  peers only. This cannot certify device Keychain use or real audio/networking.
- Fable low's final simulator-harness re-review reported nothing further to fix.
  The final wording-only update also compiled successfully without signing.
- A bounded media-only v2 control schema is being added in standalone networking
  files for subscription/ticket/clock/anchor/pause/resync/IDR messages. It does not
  authorize ownership or voice consent, and does not yet connect app playback.

Next required integration: admitted media-control subscription/bootstrap/timing,
separate authorized video, Mac/iOS application routing, secure saved-room migration
UI and annotation scene/overlay lifecycle. Keep the existing shipping transport
available only as explicitly legacy; do not silently downgrade secure rooms.

The new v2 library and annotation surfaces must not advertise support until their
app integration, admission and acceptance gates are complete. No release tag,
local signing or production installation is authorized by this progress file.

## Mac release split — user approved 2026-09-05

- User explicitly chose **Release Mac bug fixes first**. Future integrations in
  this checkout are preserved, paused, and not included in that release.
- Isolated release worktree: `/tmp/alo-mac-release-hVY67x`, branch
  `codex/mac-bugfix-release`, based on remote `b13e023` (0.13.46). This preserves
  the newer remote UI, shared room icons, and update indicator.
- Shipping commit `b1a4778a5f0e88765f951723f7f5b631b3f8e127` pushed to main;
  tag `v0.13.47` (build 78). GitHub release created with latest=false pending
  signed/notarized assets; workflow run `33932740843` is in progress.
- Exact Mac subset passed **295 tests / 42 suites** and release-mode build.
  Logs: `/tmp/alo-mac-release-final-tests.log`,
  `/tmp/alo-mac-release-final-build.log`. Fable low full/recheck/delta reviews:
  `/tmp/alo-mac-release-review.log`, `/tmp/alo-mac-release-review-final.log`,
  `/tmp/alo-mac-release-video-final-review.log`; final delta has no findings.
- No local signing, production install, or production data migration performed.
- IMPORTANT before resuming integration: this original dirty checkout remains
  at `3d576f7`; DO NOT blindly pull or overwrite it. Integrate the new remote
  commits deliberately, preserving moved networking/decoder code and all future
  work. Existing safety stash `1b4bc607950f56890deaef68ab06bd25ce3315a3` remains.
- Release-only follow-up fixes must carry into the future implementation:
  checked clock conversions in RoomTiming/SynchronizedPlayer; private video TLS
  repair (this one line already copied here); five-second video stall budget;
  suppressed keyframe requests while a sender is blocked; generation-safe timing
  and async decode-error admission; terminated Receiver video-connection cleanup.
- New `MediaReceiverSession.swift` and SecurePeerChannel executor/endpoint accessors
  here are uncompiled/unverified, excluded from the Mac release. MediaHostSession
  has 13 tests, but only its initial 11 were included in the earlier focused run.
  Shared v2 media and annotation app wiring is still incomplete.

### Release CI correction

- CI for 0.13.47 exposed a test-fixture pacing bug: relative sleeps reduced the
  intended 48 kHz offered load on a delayed runner, so the deliberately unbounded
  congestion case did not build its required one-second backlog. No app assets
  were published. The release is now draft; its original tag was not moved.
- Reproduced with injected 35 ms scheduler oversleep, then fixed the fixture to
  use absolute callback deadlines and nominal capture timestamps. Kept all shaped
  latency assertions and added both unbounded and bounded direct controls. The
  bounded normal-wakeup control still requires >=190/200 packets; delayed-wakeup
  stress explicitly logs the expected drop tradeoff instead of hiding it.
- 0.13.48/build79 commit `8cf69c79f8dbde5b637fb72b98182e5940972c50` pushed and
  tagged, release created latest=false, CI run `33933960044` in progress.
  Production logic unchanged from the Mac fix commit. New tests are only in the
  isolated release worktree; remember them when integrating remote later.
- Local 295-test full suite passed again; final added direct-control cases passed
  focused validation. Fable low final test review has no actionable findings:
  `/tmp/alo-01348-control-final-review.log`. Other evidence:
  `/tmp/alo-01348-full-tests.log`, `/tmp/alo-capture-pacing-red.log`,
  `/tmp/alo-capture-pacing-final-green.log`.

### Additional sender regression exposed by CI

- Run `33933960044` failed the restored normal unshaped bounded-delivery check:
  only 87/200 packets reached a peer, despite zero injected scheduler oversleep.
  Latency remained low, but loss is unacceptable. No 0.13.48 app assets were
  published; that release is now draft and its immutable tag remains unchanged.
- Investigating the production sender's single pending-packet slot, which drops
  short capture/completion bursts once eight sends are outstanding. Reproduce
  deterministically before changing production; retain the shaped congestion
  latency assertions and normal direct-delivery guarantee.
- Continue in `/tmp/alo-mac-release-hVY67x`; future nearby/iOS/annotation work in
  this checkout remains paused and excluded. Do not blindly pull into this
  dirty checkout. Validate the next candidate on CI before tagging it.

### 0.13.49 candidate verification

- Candidate commit `6aacbf63721b08b316c628f5c9648937bf28dfd1` is on remote
  `codex/mac-bugfix-release` only; no new tag/release yet. Preflight workflow
  dispatch run `33935870767` is running the full suite and remote packaging.
- Sender now preserves a bounded FIFO through brief callback stalls, switches
  to latest-only when backlog exceeds 16 packets/80 ms of captured audio, and
  recovers once pending is empty and in-flight use falls to half capacity.
  Separate 80 ms queue-wait expiry and shared playout expiry bound stale data.
- Deterministic red/green regressions include brief bursts, 60 ms completion
  delay, 120 ms acquisition delay, idle expiry, partial-drain recovery, client
  replacement, pause/resync/stop. Final focused direct paths delivered200/200;
  shaped congestion stayed150/189ms with no audible lateness.
- Evidence: `/tmp/alo-audio-recovery-red.log`,
  `/tmp/alo-audio-recovery-green.log`. Fable recheck running in
  `/tmp/alo-01349-recovery-review.log`. Earlier final review caught recovery
  hysteresis and was addressed before this candidate.
- A 302-test full run hit two unexplained pre-connection join timeouts. Both
  tests passed five repeats, then the full302-test suite passed on rerun.
  Diagnostic-only connection-state logs added; no timeout/retry weakening.
  Exact committed303-test suite now running separately at
  `/tmp/alo-01349-committed-tests.log`; CI must pass before publishing.
- Carry these sender and test changes into the future extracted networking
  implementation deliberately, alongside the earlier Mac release-only fixes.

### Resume after temporary-directory cleanup — 2026-09-05 afternoon

- `/tmp/alo-mac-release-hVY67x` and temporary logs disappeared during the pause.
  Candidate6aacbf6 was safely committed/pushed. Restored release-only checkout:
  `/Users/raj/.codex/worktrees/alo-mac-release-1WX1BI`, branch
  `codex/mac-release-verify`. Durable validation logs now live at
  `/Users/raj/.codex/alo-release-validation/`.
- CI33935870767 failed only because the congestion fixture insisted on receiving
  terminalpacket199 despite the new sender's intentional80ms pending expiry.
  Corrected drain verification to account for actual issued/completed/received
  packet sets and exact live peers, within the original5s budget. Retained all
  old throughput/latency assertions and added packet-accounting, continuity,
  expired-tail, minimumdelivery, and all-packet age guards.
- Reproduced another issue before fixing: an already-expired pending head made
  fresh capture look congested because span was checked before expiry. Fixed
  ordering; sender now exposes drop-reason counters in diagnostics and logs
  capture-age expiry with rate limiting. Deterministic red/green evidence saved.
- Current candidate `b7bac5ebe35b3845a9bd22aad180123e5c4f47ba` is pushed only to
  `codex/mac-release-verify`. Preflight CI33958470424, final local full suite,
  and Fable low re-review are running. No49tag or release yet; publiclatest46.
- Original dirty future-work checkout remains untouched except this handoff.
  Integrate the later Mac sender/diagnostic/test commits deliberately when
  resuming extracted nearby networking and annotations.

### Deterministic deadline investigation — 2026-09-05

- b7bac5e passed the local full306-test suite and Fable low review. Its remote
  preflight33958470424 nevertheless failed real-network timing assertions and
  a late-listener test that used capture timestamps aged by real setup waits.
- Removed test-only full PCM decoding from the sender's serial timing probe;
  retained strict validated header reads and full PCM decode at each receiver.
  Measured1600 debug probe calls: full decode2646ms, header-only80ms. CI tests
  now target the release optimization configuration; all latency limits remain.
  The lifecycle-only test now uses an injected capture clock. Both focused
  probe/lifecycle tests passed. Fable reviewed these changes without findings.
- Added complementary deterministic source/wire simulation exercising the real
  HostServer, packetizer, queue policy, TCP joins and TCP resync delivery. Real
  UDP tests remain required. Virtual timing reproduced a real admission flaw:
  capture-to-admission124.928ms plus local simulated send127.488ms exceeds the
  shared250ms deadline by2.416ms. No thresholds/event timing changed to hide it.
- media_host_adapter is implementing observed-local-send-service admission
  budgeting, explicit drop counters and stall/recovery tests in the release
  worktree. Local completion must not be described as remote delivery proof.
  Fable policy consultation running in durable review-admission-policy.log.
- No49tag/release exists. Latest public download remains0.13.46. Release is
  blocked on genuine green focused/full tests and remote packaging preflight.
  An earlier release-config compile was aborted because a source file changed
  during compilation: freeze ALL Swift files throughout builds; initial WMO
  test compilation can take8+minutes. Durable logs are not under/tmp.

### Latest candidate and new user drift report — 2026-09-05

- b18df8b737c5cdba5971185dbe4ad362840279df adds observed local completion
  admission budgeting. Deterministic worstcase252.416ms→231.792ms; direct
  fast links200/200, giantstall recovery/private audio and14focusedtests pass.
  Fable final review found no blocking production issues; its low test finding
  was addressed by enforcing>=190fastlinkdelivery in BOTH virtual wake cases.
- Release-mode Swift tests compile but this toolchain invokes the app's async
  main through SwiftTesting helper instead of tests (unknown--test-bundle-path).
  Also reproduced with-no-whole-module-optimization. Preflight33960247551
  failed, not a test pass. CI restored original debug swift test --no-parallel;
  header-only sender timing probe remains, no real-network limits relaxed.
- User newly reports long-running YouTube screen/audio drift and requests
  reliable desync detection. Exact physical-device issue still not proven fixed.
  Read-only audit found UI main.async perimage remained unbounded downstream
  of bounded presentation queue; debugroomReady also reliedonlyonRTT.
- Test-first RED sync-detection-red.log reproduces stale privatequeue handoff
  whilemainblocked and falseReady for150mslate/absentrendering. Changed video
  presentation timer to mainqueue(injectablefortests), GUIcallback directifmain,
  boundedlatestdue frames retainedwhileblocked, timingmeasuredathandoff.
  Added fresh actual renderdrift+age tooptionalbackwardcompatible syncreport,
  local/hostdiagnostics; no recoverypolicychange. Diagnosticsdon'tpass onRTT
  alone, stale/missing/drifted playback warns; staticvideoabsence notastall.
- b74aed4 is latest releaseworktreecommit, pushed to codex/mac-release-verify.
  Full316tests45suitesPASS136.809s in01349-sync-detection-full.log. Fable low
  review ongoing inreview-sync-detection.log. New remote preflight dispatched;
  resolve runID fromghlist. No49tag/releaseyet. Originalfuturework preserved.

### Final review/test checkpoint

- Latest candidate44387947c1a1927f04e5b6bb11a6a9ef3e439bd4 on
  codex/mac-release-verify. Fable review-sync-detection.log followups addressed:
  broadcaster branch tests/detailed anonymous missing-drift/age messages;
  clearer deadline-miss label; internal videoqueue generation now invalidates
  a frame extracted before reset but not yet admitted for handoff. RED/GREEN
  regression saved asvideo-reset-admission-{red,green}.log.
- FINAL318tests45suitesPASS135.230s in01349-final-318-tests.log. Fable final
  review-sync-final.log completed with 'No actionable findings'. Exactcommit
  remote preflight33961142710 is running. Priorb74aed4 preflight33960947987
  passedfulltests and is packaging; neverpublishthatolderartifact.
- Stillno49tag/release. Once exactcommit preflightpasses signing/notary, fetch
  remotefresh, fast-forwardmainonly, create immutable49tag and publish verified
  artifacts/version49build80. Publiclatest46untilfinalverification.

- Preflight33960947987(b74aed4) completedSUCCESS including tests, packaging,
  signing, notarization and Gatekeeper. Exactfinal4438794 firstattempt
  33961142710 failed two liveUDP35mswake timing bounds only: singlelistener
  final123ms(<100required), bounded8peer peak279ms(<250required), final224ms
  andzeroaudiblelateness; deterministicmodel and allnewdetectiontests passed.
  Comparison b74aed4→4438794 has NO audio transport changes. Logs preserved in
  01349-final-preflight-failed.log and01349-prior-preflight-success.log.
  Inference: runner scheduling variance plausible, not assertedproven. Reran
  the exactsamecommit once via gh run rerun33961142710--failed (attempt2).
  No assertions/inputs relaxed, no speculativeproductionfix. Awaitresult;
  do notsilentlydiscard failedrun orclaim deterministicrealtimeguarantees.

### Fixture priority correction (production unchanged)

- Exact4438794 attempt2 alsofailed varyinglivebounds (nominalbounded158/200,
  injectedfinalages154/193ms, shapedpeak287ms). Localextra repeat failedonly
  unboundedreference463mswhileproductionbounded25ms/200packets passed.
  Failedlogs preserved. No release issued and no limits loosened.
- FoundconcretefixtureQoSmismatch: captureSwiftTestingworker, headlesspeerqueue
  andartificiallinkqueuehaddefaultpriority; actualcapturebackendsandReceiver
  use.userInteractive. Fixture nowmatchesproductionpriority withcaptureanchor
  startinginsideactualcapturequeue, unchanged50×20msnominaltimestamp/bursts/
  35msinjection. Addedboundedlightweightstageprobes(capturecallbackage,
  capture-to-admissionage, artificiallinkdispatchlateness), noPCMdecodecost.
- ThreefocusedrepetitionsallPASSbothcases; fastbounded200/200all6cases,
  shapedpeak<=238ms(original250msguard). fanout-qos-repeat{1,2,3}.log.
  Fable review-fixture-priority.log reportsNoactionablefindings and validates
  productionalignment; arbitraryOSstallstillpossible, notclaimedeliminated.
- CurrentHEAD e585040123296a22f0d60c6583fd6ec102cc942d pushedcandidatebranch.
  ONLYtestfilechangedfrom4438794. Newremote preflight33961973819running;
  localfull318runningin01349-production-qos-full.log. No49tag/releaseyet.

### Follow-up: desync detection must actually reach the UI and broadcaster

- QoS preflight 33961973819 failed; stage logs in
  `01349-qos-preflight-failed.log` show generated capture callback age up to
  213 ms before host admission. Local 318-test suite did pass. No release.
- A scoped active-media power assertion experiment did not eliminate local
  timing failures (only unbounded direct baseline failed in that run). Removed
  the unconfirmed experiment; logs/review retained outside the repository.
- User explicitly requested that progressive screen/audio desync be caught.
  Independent audit found live badge still derived "Synced" from rendering,
  and broadcaster reports lacked remote screen timing. A real localhost TCP
  regression reproduced healthy audio concealing a 150 ms screen handoff miss.
  Joint RED is `remote-video-live-health-red.log` (7 actual assertion failures).
- Implemented relative, optional remote-screen timing with old-peer warnings
  only during video sharing; no remote absolute-clock arithmetic. Added live
  off-main health sampling, stale-read/source-identity guards, live labels,
  bounded 16-transition redacted incident export, and transition-only OS logs.
  This does NOT measure physical display/speaker skew or alter recovery policy.
- Joint targeted GREEN: 19 tests / 5 suites, source frozen. Full suite currently
  in `01349-live-health-full.log`; Fable low read-only review currently in
  `review-remote-video-live.log`. Work remains uncommitted in durable release
  worktree until review/full validation. Latest published download is still
  v0.13.46; no v0.13.49 tag or release has been created.

### Current Mac release checkpoint: da1afa3

- User asked why release has taken hours. Acknowledged excessive debugging/review
  expansion; committed to no further scope expansion and to reporting the
  existing live timing gate directly if it still fails, rather than another
  open-ended iteration.
- Mac candidate now committed/pushed as
  `da1afa3ffe1a373555f6373fb55fd381a603ece7` on `codex/mac-release-verify`.
  All 326 tests / 47 suites passed in 147.295 seconds; evidence:
  `01349-screen-health-final-full.log`.
- Additional genuine RED/GREEN regressions: leaving preserves exported incident
  history; unavailable reads don't manufacture/evict transitions; idle checks
  avoid no-op model publishes; no-first-frame sharing warns; restarted sharing
  rearms diagnostics without changing decoder/recovery/delivery. A static frame
  that beats a restarted share's control message is conservatively unverified.
  Initial share/control ordering and already-verified static screens supported.
- Fable closure review is still running in tmux `alo-screen-health-closure`,
  log `review-screen-health-closure.log`. Prior review findings were addressed;
  do not claim closure until complete output is read.
- Exact-commit remote preflight now running:
  https://github.com/theShyamsindhia/WERAI/actions/runs/33964076829
  Requires full test gate plus signed/notarized packaging. Nothing released yet.
  No local signing, installed-app mutation, main/tag push, or iOS/future-plan
  integration changes. No49tag/release exists. Remote main still8cf69c7 on fetch.

### Release held: current CI failure, no further open-ended iteration

- Preflight33964076829 FAILED: all 7 issues are the unchanged live fanout
  timing test. Nominal bounded direct delivered158/200 (minimum190); shaped
  packet-age maximum286ms nominal/299ms injected (limit250ms); other baseline
  final-age limits also failed. Full log:
  `01349-live-health-ci-failed.log`. User was explicitly told this is the
  blocker, not signing/uploading, and no verified-fix release will be claimed.
- Closure review of da1afa3 resolved previous findings and confirmed completed
 326-test local pass. Last low finding was cached broadcaster screen proof
  surviving off/on until next report. RealTCP RED reproduced; targeted14-test
  GREEN passed. The small cache-only correction is committed/pushed as
  `60251c7` on candidate branch. Independent audio reports/ages are preserved.
- Patch-only Fable review still running at checkpoint in tmux
  `alo-host-screen-cache`, output `review-host-screen-cache.log`; read it before
  claiming review closure. No Swift build is active. Working tree is clean.
- No new CI started for60251c7: the repeated live timing gate must be isolated,
  not endlessly rerun/loosened. No main push, tag, release, or local installation.
  Latest published remains0.13.46. Original future checkout still untouched
  except these append-only handoff notes. No release-ready claim.

### Continued release unblock and remote merge: 400c831

- User reiterated continue/release ASAP while retaining requested changes. Mac
  bug-fix split remains approved; nearby/iOS/annotation integration is preserved
  in this original checkout and is not included or advertised as finished.
- Remote main advanced to 578dc91 with room-mute/menu controls, reused sender
  fixes, monotonic fixture waits and a scoped latency-critical activity. Its CI
  33966847205 still failed one 280 ms / 250 ms live timing assertion. Merged it
  into durable release-only branch at 400c831, preserving stronger deterministic
  assertions and all previously reviewed screen/audio sync telemetry. Production
  HostServer/Diagnostics are unchanged from 60251c7. No force push or dirty
  original-source modification.
- Added a bounded observational eight-receiver inline/deferred PCM A/B test.
  Deferred receipts cap at 200/peer and fully validate payloads after transport
  drainage; malformed, wrong samples, duplicates and overflow fail. Existing
  live gate remains inline and all delivery/latency limits are unchanged.
- Local focused 29 tests passed; Fable low review-merged-fixture.log completed
  with no actionable findings. Full local suite is running in
  merged-release-full-local.log. Exact-commit CI 33967620371 is running. No49tag
  or release yet. Latest published app remains0.13.46.
- Separate tiny-package optimized-test probe reproduces the Swift async-entry
  collision: release tests invoke app main instead of Testing runner. This is a
  tooling investigation only; no production entrypoint or test gate changed.

### CI timing remains mandatory — 05c963e

- User explicitly rejected replacing CI live timing with the passing local Mac
  run. Keep all live timing and deterministic gates required on CI; no skips,
  no local-only substitution, no threshold weakening, and no release while red.
- 400c831 debug CI failed one114ms/100ms check. Receiver deferred-PCM A/B did
  not consistently improve source scheduling; existing live tests still use
  inline complete PCM decoding. No production tuning based on that hypothesis.
- Tiny package reproduced optimized async-main compiler collision. Disabling
  only CapturePropagation for C main fixes it; deliberate failing test exits1,
  fresh positive test executes, removing flags reproduces wrong entrypoint.
  Test-only flags are in workflow, never package.sh or production source.
- 2318ed4 optimized local full suite:331tests/48suitesPASS86.35s, alongside
  debug331PASS243.54s. Default-Xcode CI33968050409 still failed3timingchecks.
- 3c29dc8 pins Xcode26.3/17C529 to match validated Swift6.2.4, adds pipefail plus
  nonzero passing-Testingsummary guard, and clarifies testability vs packaged
  binary. Fable closure review-optimized-gate-closure.log no actionable findings.
  PinnedCI33968362181 still failed4timings:181/190directpackets,265ms/250msmax,
 116ms and127ms finalages/100ms. Source itself was up to207ms old beforeHostServer.
- Added observational timer-only controls before/after loadedfanout at05c963e;
  local focusedPASS1test, wakep95 4ms/max6ms, threadCPU<1ms/980ms, loaded200/200.
  CI33968858706 is running to compare sameQoS/activity/machwait withoutnetwork.
- Agent media_host_adapter is researching isolated strictDispatchTimer vs
  dedicated-thread realtime scheduling as potential fixture-only followups.
  No repository changes from that research. No new production fix is justified
  until the timer control distinguishes scheduler delay from sender load.
- Latest publicrelease0.13.46, no49tag/release. Durable releasebranch HEAD05c963e,
  origin/main last578dc91. Original nearby/iOS/annotation sources remain untouched.

### Strict capture CI fixed; published remote merged into 0.13.50 candidate

- No-network control on CI reproduced >100ms Mach timer wake delays with <1ms
  thread CPU. Strict DispatchSourceTimer preserves all nominal chunks and the
  deliberate35ms oversleep; no timing limits or full-PCM gates were weakened.
  Exact1c8dc19 CI33969583586 passed334tests, signing and notarization.
- Remote independently published0.13.49 at39b152e, main advancedb1ca5cc. Fetched
  and merged its completion-rate backlog guard and regressions; never replace
  or retag49. Candidate606e8b7 is0.13.50/build81, containsremote b1ca5cc.
- Fable low review-final-merge.log and media_host_adapter read-only review found
  no actionable correctness issue. CurrentCI33970200108 passed the full test
  step and is packaging at checkpoint. Do not publish until signature/notary
  and artifact verification complete.
- Local merged336test run had one socket setup failure, not timing: both peers
  EADDRINUSE connecting listener64373. Unified logs show64373 was just a prior
  test's outbound source port, canceled0.5sec before fresh dualstack listener
  selected that port. Agent is doing a standalone forced-port-reuse probe.
  No speculative production port-reuse flags or retries added.
- Original future integration sources remain untouched; no local signing,
  installed app replacement, or production-data change. No50tag/release yet.

### User requests 0.14.0 version; release cutoff frozen

- User explicitly asked to release as .14, so9950d97 changes only Info.plist
  marketing version to0.14.0 (build81) and renames the release notes accordingly.
  No0.13.50tag/release was created. Candidate606e8b7 had all336tests passing on
  CI33970200108 plus notarized/signature-verified artifacts (do NOT publish the
  0.13.50 binaries under0.14.0). Current0.14 CI33970607845 has passed tests and
  is packaging at this checkpoint. Full local0.14 run also passed336tests.
- Fable final focused review and independent sender review found no actionable
  findings. Earlier one-off local test EADDRINUSE is retained in evidence, not
  erased; scratch forced-port probe confirms reservation after cancel but did
  not reproduce exact listener-ready failure. No speculative workaround added.
- Remote later advanced89fe9a9 with artwork-header gradients/nativeUItests.
  User was told this arrived after release cutoff, is preserved on remote main,
  and0.14 ships from frozen9950d97 release branch without restarting validation
  for artwork-only expansion. Never force-push main or discard89fe9a9.

### Full integration is now the explicit release requirement (September 5)

- The user superseded the earlier Mac-only split: **wait for full nearby,
  iOS and annotation integration, then publish 0.14.0**. No 0.14 tag/release
  exists. Never publish the older Mac-only artifacts as this full release.
- The original unfinished work was preserved in 6ef5b24 and pushed on
  `codex/full-nearby-integration`. Latest main (including artwork and README)
  was merged in a188231 and pushed; that coherent checkpoint passed 477 tests.
- Runtime wave 1 reproduced the healthy capture-burst loss against untouched
  a188231 source: only frame 0 arrived from eight frames [0,240,...,1680].
  Red evidence is `/tmp/alo-media-burst-red-erGgsp/red.log`. The bounded FIFO
  fix now preserves this burst; cancellation, expiry and overload are tested.
- Wave 1 full run compiled and ran 508 tests. It found one real active-pause
  state regression and two native snapshot barrier failures. These were fixed;
  the artwork pixel/contrast requirements were NOT relaxed. A phase marker and
  stable native rasters replace an arbitrary sleep; fixture colors use sRGB.
- Fable low reviewed runtime wave 1 (review-runtime-wave1.log outside repo).
  Findings covered active preparation failure, stale Mac render state, FIFO
  eviction, annotation budget cost, bridge overflow ownership and cutover clock
  changes. Fixes are in progress/covered by the next focused run, not a claim
  of a final clean release review. Persistent annotation tools are intentional.
- Wave 2 focused run passed 53 tests in 10 suites, including real admitted audio
  bootstrap/rejoin/renewal, active refresh rejection, independent video channel
  authorization/chunking/repair, render handoff, capture metadata, secure-room
  selection, bounded UI bridges and both artwork appearances.
- Mac app source now constructs secure media host/receiver for secure rooms,
  retains explicit legacy policy for existing rooms, creates new rooms with
  secure identities, and uses bounded discovery windows. Mac secure video and
  annotation viewer are wired. Presenter annotation runtime, mobile video/voice,
  authenticated hardware-floor reporting, remaining review follow-ups and full
  runtime/device acceptance are still pending. Do not advertise completion.
- Wave 2 full run passed 528 tests in 78 suites (157.920 seconds), and the
  unsigned Debug iOS simulator build passed with CODE_SIGNING_ALLOWED=NO.
  Remote main advanced to 1732660 with branding, games and chat fixes; merge
  those after preserving this tested runtime checkpoint.
- Temporary identities stay
  restricted to the explicitly approved isolated Debug simulator flag. No local
  signing or installed app/data changes were made. All live timing CI gates
  remain mandatory; local timing does not replace them.

### Runtime wave 3 checkpoint

- a5a4129 merged main 1732660 and is pushed. The renamed origin is
  `theShyamsindhia/ALO`. Merge regressions fixed: secure signature Codable
  preservation and arena framing; 27 focused tests passed.
- Wave 3 adds mobile encrypted video, Mac presenter annotations, authenticated
  hardware-floor reports, paused-media video independence, bounded video ingress,
  optional-extension quarantine and active-anchor ACK preservation.
- A real TLS/UDP fixture now starts capture before any listener exists, joins a
  healthy listener, then joins/leaves/rejoins the same second identity twice.
  Healthy playback retains one commit and receives no duplicate frames. This is
  synthetic capture on real sockets, not a claim of acoustic/radio validation.
- Focused 60-test run passed; unsigned iOS simulator build passed. Full run ran
  603 tests and found only three finite-codec fixtures using stop as flush.
  Explicit generation-preserving fixture flushing fixes those; focused 5-codec
  tests pass. A complete rerun is required for this checkpoint.
- Fable low reviewed committed a188231..a5a4129: new follow-ups are chat author
  binding, mobile rich-chat projection, stale annotation attachment guard,
  opt-in secure ducking wiring, video failure executor, and scan-expiry UX.
  They are not yet claimed resolved or cleanly re-reviewed.
- Directed mobile/Mac v2 voice, coordinated hardware-floor cutovers, lifecycle
  acceptance and final review remain mandatory before 0.14.0. The verification
  workflow now runs the integration branch with pinned Xcode 26.3 and the same
  optimized tests/live-timing requirements as release CI.

### Runtime wave 4 integration verification

- Wave 3 was committed and pushed as ba3c19b after 603 tests passed locally.
  Its CI failed one unchanged live fanout final-age assertion (119 ms against
  100 ms). The fixture now avoids sorting/render simulation on receiver queues
  until transport drainage, and awaits actual cancellation before reusing native
  socket resources. Local live runs passed at 8 ms nominal / 44 ms injected;
  the corrected checkpoint still requires CI. No threshold was relaxed.
- Directed encrypted Mac/iOS voice, consent revalidation after each microphone
  await, independent media mute, and shared iOS annotation scenes are wired.
  Genuine scheduled mobile media permits background listening; empty engines
  and silence do not justify keeping the room alive in background.
- Future hardware-floor cutovers preserve established playback; a receiver that
  missed the cutover repairs only itself. Focused tests cover completed output
  retirement, renewal continuity, stale telemetry and missed-boundary recovery.
- Unsigned iOS simulator build passed after fixing a SwiftUI Section initializer:
  `ios-runtime-wave4-build-retry.log`. Both targets are 0.14.0/build 81. No local
  signing or installed production/development Mac data was changed.
- The 50-test focused gate found four codec failures caused by rejecting this
  Mac's read-only effective zero-delay encoder property. The failure is retained
  in `/tmp/alo-video-lookahead-after.log`. The effective numeric zero-delay
  contract is now verified before and after encoder preparation even on a
  backend that rejects its setter. The corrected focused gate passed 54 tests
  in 6 suites (`/tmp/alo-video-lookahead-final.log`), including continuous real
  encoding without fixture flushing, playback recovery, mute and voice consent.
- Remote media-level controls have no secure wire command and now explicitly
  remain unavailable in secure rooms rather than optimistically changing UI.
  Local media and per-person received voice levels remain available. This is a
  documented capability limit, not a completed remote mixer implementation.
- Full suite, latest remote merge, clean final Fable review, strict CI and device
  acceptance remain outstanding. No 0.14.0 tag or release has been created.
- Updated unsigned iOS app launched in the isolated simulator with the explicit
  temporary-identity banner; no scan, room join or microphone request occurred.
  The simulator was shut down afterward. A newly identified host pause/resume
  versus queued cutover race is being isolated in its own regression/fix.

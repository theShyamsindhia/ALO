# Room experience delivery

## Implemented

- Existing compact room aesthetic preserved, quiet status dots with accessible hover details, no permanent connection/voice/ducking dashboard. Settings hold microphone routing details, music ducking and incoming audio options.
- Resizable expanded room with remembered dimensions. Chat/People/Games remain accessible through familiar controls and compact navigation menus. Playback stays present; Sync this Mac targets only the local receiver; screen/queue actions are in More.
- Downloadable data-only game library, two native games, verified compact packs, offline content after installation. Rift supports four-player room creation with bots, ready-up, midgame bot takeover, spectating, rematch, embedded/pop-out/fullscreen, menus and controller bindings. Its articulated fighters, three layouts, layered parallax and local results ledger are implemented. Fourfold supports bot or local pass-and-play.
- Replies, reactions, own-message edit/delete, retained-history search, shared pins, mentions and in-app preview preferences. URL cards and URL drops are local text operations, no automatic remote metadata retrieval. History policy is available from chat options.
- Broadcaster UI queue ordering with backward-compatible durable carrier. Per-person persistent voice levels, optional music ducking, local microphone record/playback test, local receiving-status recovery summaries and private/public channel audit.
- Game/session, game rendering, game packs, chat UI/reducer, microphone test and voice preference code are separate files. Existing GUI.swift remains large; further mechanical extraction should preserve behavior in small follow-up changes.

- Native Touch Bar: playback, local incoming-audio mute, local sync, and More → Chat/People/Games. No polling or simulated hardware claims.
- Local automatic audio realignment with sustained drift threshold/cooldown and timing in Settings. Receiver-owned correction avoids competing host resets. Call/Bluetooth hardware testing remains required.
- Default-off lyrics lookup and collapsible chat panel; missing/ambiguous tracks have explicit states. Timed highlighting awaits a trustworthy song playhead.

## Remaining work with distinct acceptance criteria

1. **Image/file sharing:** a bounded transfer protocol outside chat operations, explicit recipients, progress/cancel, size/type limits, storage quotas, retention and privacy audit. Do not base64 attachments into the 2,000-character chat channel.
2. **Fetched link previews/OS notifications:** opt-in metadata fetching with local-network protections, preview cache and OS notification permission flow. Current cards show verified URL structure only; preview preferences govern in-app notifications.
3. **Room admission, key rotation/revocation, moderation:** authenticated durable event authorship and an explicit authority model must precede enforcing policies. Current invite keys are shared bearer secrets; rotating a local value cannot revoke a key already held by a connected participant. Queue and edit UI restrictions inherit cooperative identity guarantees. Blocking/removal must define behavior during partitions and concurrent authority changes.
4. **Shared descriptions/rules/presence:** add versioned room metadata and explicit heartbeat activity/away state. Current dots intentionally do not invent remote activity or synchronization health from connection alone.
5. **Competitive fighter development:** multi-Mac latency tests, real controller coverage, focus/cancellation tests under full-screen Spaces changes, animation sets, balance playtesting, rollback or prediction protocol, network simulation at latency/loss, Instruments energy profiling with audio/video active.
6. **Acoustic validation:** mic loopback is implemented but echo cancellation/noise suppression claims need measured speaker/headphone/Bluetooth scenarios. Test music ducking and independent voice/music/game mix on physical devices.

No commercial-game quality comparison is established by visual polish or automated tests alone.

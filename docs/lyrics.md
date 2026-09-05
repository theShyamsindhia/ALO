# Optional lyrics

Lyrics are disabled by default. Enabling the setting permits title, artist and album metadata to be sent to LRCLIB. Room names, member identities, invite keys, source URLs and audio are never included. The small lyrics disclosure remains collapsed until opened.

The provider uses the documented public `GET /api/search` endpoint, then requires matching title and artist, plus album when available. Different matching lyric versions produce an ambiguity state rather than an arbitrary choice. Responses are bounded to 512 KB; eight results are cached in memory only. Each accepted plain/synced source is limited to 128 KB. Parsed lyric rows are capped at 2,000 and 128 KB of retained text, and timed rows use a lazy stack. Disabling lyrics cancels the current request. Track changes discard stale responses. `Retry-After` blocks further requests; failures have an explicit retry action. No lyrics are bundled with the app or these tests.

The present room metadata does not carry duration or a reliable playback position. Lyrics therefore display without timed highlighting. `LyricsPanel.position` is an optional extension point for a future playhead that correctly handles seeks, pauses and receiver latency. It must not be derived from the time a track's metadata arrived. Adding elapsed time to the existing metadata monitor would also require accounting for durable playback-event traffic.

API reference: [LRCLIB documentation](https://lrclib.net/docs). Native provider attribution links to LRCLIB.

Integration:

- Retain one `LyricsController` on the room model.
- Bind a default-off Settings toggle to `controller.enabled`, with `LyricsController.privacyNotice` immediately beside it.
- Call `controller.update(media:)` when the actual shared now-playing metadata changes, including initial state. Missing/cleared metadata clears lyrics.
- Insert `LyricsPanel(controller: controller, accent: roomAccent)` near playback. It has no visible surface when disabled and is collapsed by default.
- Call `controller.cancel()` when tearing down the room, and update with current metadata on re-entry.

Tests use synthetic fixture text and cover metadata scope, exact matching, ambiguity, timestamp parsing, absent playheads, retry limits, disabled state and cancellation/stale-response handling.

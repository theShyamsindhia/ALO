# Optional lyrics

Lyrics are disabled by default. Enabling the setting under the main room settings icon permits title, artist and album metadata to be sent to LRCLIB. Room names, member identities, invite keys, source URLs and audio are never included. The current line appears below the player status and opens the full lyrics view when clicked; lyrics are not inserted into room messages or the chat transcript.

The provider uses the documented public `GET /api/search` endpoint, then requires matching title and artist, plus album when available. Different matching lyric versions produce an ambiguity state rather than an arbitrary choice. Responses are bounded to 512 KB; eight results are cached in memory only. Each accepted plain/synced source is limited to 128 KB. Parsed lyric rows are capped at 2,000 and 128 KB of retained text, and timed rows use a lazy stack. Disabling lyrics cancels the current request. Track changes discard stale responses. `Retry-After` blocks further requests; failures have an explicit retry action. No lyrics are bundled with the app or these tests.

Upstream playback-progress metadata carries optional duration and elapsed time. Timed results select the current line from the shared playback position; opening the full view centers that line immediately and continues following timestamp changes. Untimed results show the first available line in the player and the full text on demand because plain lyrics do not contain enough information for reliable automatic scrolling. Track receipt time alone is not used as a lyric clock.

API reference: [LRCLIB documentation](https://lrclib.net/docs). Native provider attribution links to LRCLIB.

Integration:

- Retain one `LyricsController` on the room model.
- Bind a default-off Settings toggle to `controller.enabled`, with `LyricsController.privacyNotice` immediately beside it.
- Call `controller.update(media:)` when the actual shared now-playing metadata changes, including initial state. Missing/cleared metadata clears lyrics.
- Insert `LyricsPlayerLine` beneath the playback status and present `LyricsPanel` on demand. Neither has a visible surface when disabled.
- Call `controller.cancel()` when tearing down the room, and update with current metadata on re-entry.

Tests use synthetic fixture text and cover metadata scope, exact matching, ambiguity, timestamp parsing, absent playheads, retry limits, disabled state and cancellation/stale-response handling.

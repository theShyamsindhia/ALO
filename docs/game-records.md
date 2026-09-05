# Games library and local results

The Library tab opens downloaded content packs only after Play is selected; installing a pack does not launch a game. Installed cover art is downsampled once to 640 pixels for the library. Removal is a secondary action in each game's More menu.

The Leaderboard tab shows real Rift Arena results recorded on this Mac. It is not a server or room-wide ranking. The store retains up to 1,000 completed results and deduplicates game/session/round IDs across restarts. Stable participant IDs distinguish players, while the latest recorded display name appears in the table.

A match needs at least two human participants. Bots do not receive standings. If a bot wins a mixed match, the human participants each gain one played match and no win or draw. Single-player practice, one-person bot matches, missing participant identities, and unfinished matches are excluded.

`ArenaRecordStore.shared.record(ArenaMatchResult)` is the completed-match callback. `GameLibraryView` observes that same shared store. Results use an atomic local JSON write and remain outside durable chat and network game frames. The UI reports a local save error without inventing successful results.

Tests cover empty state, win/draw totals, reload and duplicate protection, changed display names, four-player results, bot victories and practice exclusion.

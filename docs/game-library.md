# Games library and downloadable content

The room's Games library lists real games supported by the installed app: Rift Arena (four-player room matches, bots, spectating) and Fourfold (bot or pass-and-play on the same Mac). Artwork-led cards keep download/install/update actions visible and put removal in More. Progress, verification, retry/cancel and version details remain available. Installed packs can be loaded offline, updated or removed. Rift matches require a room; Fourfold also supports local play. An unsuccessful update keeps the previous installation intact.

Native engines and multiplayer protocols ship with ALO. Downloaded packs change artwork, arena naming, descriptions and theme colors. Version 4 of Rift includes five fighter portraits, Moon Garden, transparent parallax and stone-platform artwork and requires the five-fighter native engine; the library prompts older app versions to update ALO. Version-1 pack files remain immutable.

Packs cannot add native code, scripts, executables, dynamic libraries or new mechanics; those changes require an app update. This is deliberate: content releases can stay small and independent without running downloaded code.

## Release a content pack

Catalog: `https://raw.githubusercontent.com/theShyamsindhia/ALO/main/GamePacks/catalog.json`.
The fallback compiled into the app contains only tiny catalog metadata, never game artwork. When the network is unavailable, installed content still loads. A first download requires network access and the published repository files.

The repository contains data-only JSON packs under `GamePacks/<game-id>/<version>/pack.json`. Source artwork lives under `GamePacks/source-art`. `Scripts/update_game_catalog.py` generates the current packs, their exact SHA256/byte pins, the remote catalog and the tiny Swift fallback. Run it whenever source artwork changes before release. For later content releases, increase the entry’s `version` in that script and publish a new versioned path plus catalog entry; keep prior versioned content immutable so old catalog pins continue to work. Add a new engine ID only when its native engine actually ships.

Pack installation accepts only HTTPS URLs on this repository's `raw.githubusercontent.com/.../main/GamePacks/` path. It bounds catalog bytes, streamed download bytes, metadata lengths, image bytes and image dimensions. The catalog pins each complete pack's SHA256; a size/hash mismatch aborts installation. Images are validated PNG/JPEG data, not file paths or archives. Installation atomically replaces a single verified JSON file in `~/Library/Application Support/ALO/GamePacks`. There is no archive extraction, path traversal, shell execution or downloaded executable code. Canceling a transfer does not replace installed content.

The catalog is trusted through repository control and HTTPS. Its hashes authenticate downloaded bytes against that catalog; they are not a separate publisher signature. Existing game versions and protocol compatibility are still managed by the app release.

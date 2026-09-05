# DynamicNotch source import

`DynamicNotch/` is an unchanged copy of the user-provided `DynamicNotch-main` directory,
imported September 6, 2026. Upstream: https://github.com/jackson-storm/DynamicNotch.
No Git commit metadata was included in the supplied directory.

The upstream source is licensed under GNU GPL v3; see `DynamicNotch/LICENSE`.
Its copyright headers remain intact. The root ALO MIT license does not replace the
license of this imported code. Distribution of a combined build must account for the
upstream GPL terms.

Nine original dependency-light Swift files are compiled from `Sources/ALO/DynamicNotch/`.
`DynamicNotch-import.json` records their source paths and SHA-256 hashes.
`Sources/ALO/ALONotch.swift` is the ALO-specific state, window and settings adapter.
The rest of the snapshot is source-only, outside SwiftPM targets. It includes the
upstream settings, assets, tests, and system integrations for future porting.

See `../docs/dynamic-notch-features.md` for the inventory and integration requirements.

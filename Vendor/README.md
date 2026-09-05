# DynamicNotch source integration

`DynamicNotch/` was copied from the user-provided `DynamicNotch-main` directory on
September 6, 2026. The initial unchanged snapshot is retained in commit `a6d26f7`.
Upstream: https://github.com/jackson-storm/DynamicNotch. No upstream Git metadata was
included in the supplied directory.

The full feature source is now compiled as the separate `ALONotchRuntime` SwiftPM
target. Adaptations in place add opt-in defaults, service lifecycle control, isolated
settings storage, packaged resource lookup, and ALO window embedding. Original
copyright headers remain intact. The standalone entrypoint, onboarding, updater,
and donation animation code are excluded from ALO. The original nine primitives in
`Sources/ALO/DynamicNotch/` still drive ALO room motion; their copy hashes remain in
`DynamicNotch-import.json`.

The upstream code is GNU GPL v3; see `DynamicNotch/LICENSE`. The ALO MIT license does
not replace those terms. Packaged builds include the GPL text, MediaRemoteAdapter's
BSD 3-Clause license, dependency notices, and a reference to corresponding source.

`Scripts/prepare_notch_resources.py` generates SwiftPM-compatible localization and
named image resources from the original Xcode catalogs. Generated files are checked
in so builds do not require Python. Run it again after changing the catalogs.

See `../docs/dynamic-notch-features.md` for feature settings and dependencies, and
`../docs/notch-validation.md` for validation and remaining hardware-dependent checks.

# ALO

Listen together.

ALO is the public product and repository name. Use uppercase **ALO** in copy;
`alo` remains the executable name. Do not introduce a second public name.

## Assets

- [ALO icon](../../Resources/ALOLogo-1024.png): the approved blue-and-coral `alo` lettering on a pearl macOS tile. The packaged Mac app and README use this master.
- [Layered SVG](alo-layers/alo-layered.svg): editable vector reconstruction, with named background, coral terminal, and blue lettering layers. This is an approximation of the rendered artwork, not a lossless conversion. The app uses the approved raster, not this reconstruction.
- Separate transparent SVGs: [background](alo-layers/background.svg), [lettering](alo-layers/lettering.svg), [accent](alo-layers/accent.svg). All share a 1254 × 1254 viewBox for alignment.
- `Sources/ALO/Resources/AppIcons`: the approved original and all 15 subsequent variations, resized to 1024 × 1024 without changing their artwork or presentation backgrounds. `Scripts/import-app-icons.swift` records their source identifiers and reproduces the imports from the generated-image directory.

Use the approved raster file directly for production. Keep its proportions.
The README pairs a small, unmodified icon with a native text heading. The social
preview uses the original square PNG, not a generated banner or lookalike.

## Settings

Open ALO → Settings… (⌘,). The icon picker saves `ALO.selectedAppIcon` in local
UserDefaults and reapplies it at launch. Restore Default selects the blue/coral
master. Alternatives change the running Dock icon; Finder and the installed
bundle keep the default. No app-bundle mutation or re-signing occurs on selection.
Shortcut Mapper remains available from the ALO menu.

The package script embeds `ALO_ALO.bundle` alongside AppIcon.icns inside
Contents/Resources. Rebuild the app to pick up the new default icon.

## Compatibility

The GitHub home is https://github.com/theShyamsindhia/ALO. Downloads retain their
`ALO-macos-arm64` filenames. The bundle ID, local data, Keychain, Bonjour names,
and legacy audio interfaces are compatibility contracts, not public branding.
Preserve them so existing installations continue to work.

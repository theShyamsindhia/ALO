#!/bin/zsh

set -euo pipefail

cd "${0:A:h}/.."

architectures=(arm64 x86_64)
archive_suffix="universal"
if [[ "${1:-}" == "--arm64-only" ]]; then
    architectures=(arm64)
    archive_suffix="arm64"
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--arm64-only]" >&2
    exit 2
fi

for architecture in "${architectures[@]}"; do
    swift build -c release --arch "$architecture"
done
mkdir -p dist

binary="dist/werai"
cli_archive="dist/werai-cli-macos-$archive_suffix.zip"
app="dist/WERAI.app"
app_archive="dist/WERAI-macos-$archive_suffix.zip"
codesign_identity="${WERAI_CODESIGN_IDENTITY:--}"
codesign_arguments=(--force --sign "$codesign_identity" --identifier in.werai.audio)
if [[ "$codesign_identity" != "-" ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi

if [[ ${#architectures[@]} -eq 1 ]]; then
    cp ".build/${architectures[1]}-apple-macosx/release/werai" "$binary"
else
    lipo -create \
        .build/arm64-apple-macosx/release/werai \
        .build/x86_64-apple-macosx/release/werai \
        -output "$binary"
fi
codesign "${codesign_arguments[@]}" "$binary"

icon_master="dist/AppIcon-1024.png"
iconset="dist/AppIcon.iconset"
mkdir -p "$iconset"
swift Scripts/make_icon.swift "$icon_master"

for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size=${specification%% *}
    name=${specification#* }
    sips -z "$size" "$size" "$icon_master" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o dist/AppIcon.icns

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/werai"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp dist/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [[ "$codesign_identity" == "-" ]]; then
    codesign "${codesign_arguments[@]}" \
        --requirements Resources/WERAI.requirements \
        "$app"
else
    codesign "${codesign_arguments[@]}" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

rm -f "$cli_archive" "$app_archive"
ditto -c -k "$binary" "$cli_archive"
(
    cd dist
    zip -qry "WERAI-macos-$archive_suffix.zip" WERAI.app
)

echo "Created $app_archive"

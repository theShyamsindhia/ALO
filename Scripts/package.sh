#!/bin/zsh

set -euo pipefail

cd "${0:A:h}/.."

swift build -c release --arch arm64
swift build -c release --arch x86_64
mkdir -p dist

binary="dist/werai"
cli_archive="dist/werai-cli-macos-universal.zip"
app="dist/WERAI.app"
app_archive="dist/WERAI-macos-universal.zip"

lipo -create \
    .build/arm64-apple-macosx/release/werai \
    .build/x86_64-apple-macosx/release/werai \
    -output "$binary"
codesign --force --sign - "$binary"

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
codesign --force --deep --sign - \
    --identifier in.werai.audio \
    --requirements Resources/WERAI.requirements \
    "$app"

rm -f "$cli_archive" "$app_archive"
ditto -c -k "$binary" "$cli_archive"
(
    cd dist
    zip -qry WERAI-macos-universal.zip WERAI.app
)

echo "Created $app_archive"

#!/bin/zsh

set -euo pipefail

cd "${0:A:h}/.."

architectures=(arm64 x86_64)
archive_suffix="universal"
development_build=false
for argument in "$@"; do
    case "$argument" in
        --arm64-only)
            architectures=(arm64)
            archive_suffix="arm64"
            ;;
        --dev)
            development_build=true
            ;;
        *)
            echo "Usage: $0 [--arm64-only] [--dev]" >&2
            exit 2
            ;;
    esac
done

for architecture in "${architectures[@]}"; do
    swift build -c release --arch "$architecture"
done
mkdir -p dist

if $development_build; then
    binary="dist/alo-dev"
    app="dist/ALO Dev.app"
    bundle_identifier="in.werai.audio.dev"
else
    binary="dist/alo"
    app="dist/ALO.app"
    bundle_identifier="in.werai.audio"
fi
cli_archive="dist/alo-cli-macos-$archive_suffix.zip"
codesign_identity="${ALO_CODESIGN_IDENTITY:-${WERAI_CODESIGN_IDENTITY:--}}"
codesign_arguments=(
    --force
    --sign "$codesign_identity"
    --identifier "$bundle_identifier"
    --entitlements Resources/ALO.entitlements
)
if [[ "$codesign_identity" != "-" ]]; then
    codesign_arguments+=(--options runtime)
    if [[ "${ALO_CODESIGN_TIMESTAMP:-${WERAI_CODESIGN_TIMESTAMP:-automatic}}" == "none" ]]; then
        codesign_arguments+=(--timestamp=none)
    else
        codesign_arguments+=(--timestamp)
    fi
    signing_keychain="${ALO_SIGNING_KEYCHAIN:-${WERAI_SIGNING_KEYCHAIN:-}}"
    if [[ -n "$signing_keychain" ]]; then
        codesign_arguments+=(--keychain "$signing_keychain")
    fi
fi

run_codesign() {
    if [[ "$codesign_identity" == "-" ]]; then
        command codesign "$@"
        return
    fi

    command codesign "$@" &
    local codesign_pid=$!
    (
        sleep "${ALO_CODESIGN_TIMEOUT_SECONDS:-${WERAI_CODESIGN_TIMEOUT_SECONDS:-120}}"
        if kill -0 "$codesign_pid" 2>/dev/null; then
            echo "codesign timed out while accessing the signing key or Apple timestamp service" >&2
            kill -TERM "$codesign_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!
    local codesign_status=0
    wait "$codesign_pid" || codesign_status=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    return "$codesign_status"
}

if [[ ${#architectures[@]} -eq 1 ]]; then
    cp ".build/${architectures[1]}-apple-macosx/release/alo" "$binary"
else
    lipo -create \
        .build/arm64-apple-macosx/release/alo \
        .build/x86_64-apple-macosx/release/alo \
        -output "$binary"
fi
if [[ "$codesign_identity" == "-" ]]; then
    run_codesign "${codesign_arguments[@]}" "$binary"
fi

icon_master="Resources/ALOLogo-1024.png"
iconset="dist/AppIcon.iconset"
mkdir -p "$iconset"
test -f "$icon_master"

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

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/alo"
cp Resources/Info.plist "$app/Contents/Info.plist"
if $development_build; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ALO Dev" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ALO Dev" "$app/Contents/Info.plist"
fi
cp dist/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R ".build/${architectures[1]}-apple-macosx/release/ALO_ALO.bundle" "$app/Contents/Resources/ALO_ALO.bundle"
cp Resources/ALOSetupBackground.png "$app/Contents/Resources/ALOSetupBackground.png"
for setup_slide in Resources/ALOSetupSlide-*.jpg; do
    cp "$setup_slide" "$app/Contents/Resources/${setup_slide:t}"
done
if [[ "$codesign_identity" == "-" ]]; then
    if $development_build; then
        run_codesign "${codesign_arguments[@]}" "$app"
    else
        run_codesign "${codesign_arguments[@]}" \
            --requirements Resources/ALO.requirements \
            "$app"
    fi
else
    run_codesign "${codesign_arguments[@]}" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

if $development_build; then
    echo "Created $app with isolated bundle id $bundle_identifier"
    exit 0
fi

rm -f "$cli_archive"
ditto -c -k "$binary" "$cli_archive"
./Scripts/create_distribution_archives.sh "$archive_suffix"

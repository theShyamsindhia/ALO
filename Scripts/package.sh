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
nested_codesign_arguments=(--force --sign "$codesign_identity")
if [[ "$codesign_identity" != "-" ]]; then
    codesign_arguments+=(--options runtime)
    nested_codesign_arguments+=(--options runtime)
    if [[ "${ALO_CODESIGN_TIMESTAMP:-${WERAI_CODESIGN_TIMESTAMP:-automatic}}" == "none" ]]; then
        codesign_arguments+=(--timestamp=none)
        nested_codesign_arguments+=(--timestamp=none)
    else
        codesign_arguments+=(--timestamp)
        nested_codesign_arguments+=(--timestamp)
    fi
    signing_keychain="${ALO_SIGNING_KEYCHAIN:-${WERAI_SIGNING_KEYCHAIN:-}}"
    if [[ -n "$signing_keychain" ]]; then
        codesign_arguments+=(--keychain "$signing_keychain")
        nested_codesign_arguments+=(--keychain "$signing_keychain")
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

# Older ALO updaters deliberately reject archive links. Materialize only links
# whose targets stay inside the built resource bundle before signing so the
# release remains installable from those versions without weakening that guard.
copy_resource_bundle_without_symlinks() {
    local source="$1"
    local destination="$2"
    local source_root link resolved framework
    source_root="$(/bin/realpath "$source")"
    while IFS= read -r -d '' link; do
        resolved="$(/bin/realpath "$link")" || return 1
        if [[ "$resolved" != "$source_root"/* ]]; then
            echo "Refusing resource link outside its bundle: $link" >&2
            return 1
        fi
    done < <(/usr/bin/find "$source" -type l -print0)
    /bin/cp -RLp "$source" "$destination"
    # A versioned framework becomes ambiguous if both its materialized root
    # aliases and Versions tree remain. Keep the standard flat representation
    # that codesign and the runtime loader both understand.
    while IFS= read -r -d '' framework; do
        if [[ -d "$framework/Versions" ]]; then
            /bin/chmod -R u+w "$framework/Versions"
            /bin/rm -R "$framework/Versions"
        fi
    done < <(/usr/bin/find "$destination" -type d -name '*.framework' -prune -print0)
    if [[ -n "$(/usr/bin/find "$destination" -type l -print -quit)" ]]; then
        echo "Resource bundle still contains a symbolic link: $destination" >&2
        return 1
    fi
}

# Resource bundles contain the original notch assets and the MediaRemote helper.
# Sign nested native code before sealing either the bundle or its containing app,
# and do not give helpers ALO's bundle identifier or microphone/camera entitlements.
sign_runtime_code() {
    local resource_directory="$1"
    local native_file framework
    while IFS= read -r -d '' native_file; do
        [[ "$native_file" == *.framework/* ]] && continue
        if /usr/bin/file -b "$native_file" | /usr/bin/grep -q 'Mach-O'; then
            for architecture in "${architectures[@]}"; do
                lipo "$native_file" -verify_arch "$architecture"
            done
            run_codesign "${nested_codesign_arguments[@]}" "$native_file"
        fi
    done < <(/usr/bin/find "$resource_directory" -type f -print0)
    while IFS= read -r -d '' framework; do
        local framework_name="${framework:t:r}"
        for architecture in "${architectures[@]}"; do
            lipo "$framework/$framework_name" -verify_arch "$architecture"
        done
        run_codesign "${nested_codesign_arguments[@]}" "$framework"
        codesign --verify --strict "$framework"
    done < <(/usr/bin/find "$resource_directory" -depth -type d -name '*.framework' -print0)
}

runtime_bundle_name="ALO_ALONotchRuntime.bundle"
runtime_bundle_source=".build/${architectures[1]}-apple-macosx/release/$runtime_bundle_name"
test -d "$runtime_bundle_source"
resource_bundles=()
for built_resource_bundle in .build/${architectures[1]}-apple-macosx/release/*.bundle(N); do
    packaged_resource_bundle="dist/${built_resource_bundle:t}"
    rm -rf "$packaged_resource_bundle"
    copy_resource_bundle_without_symlinks "$built_resource_bundle" "$packaged_resource_bundle"
    sign_runtime_code "$packaged_resource_bundle"
    resource_bundles+=("$packaged_resource_bundle")
done

notices="dist/ThirdPartyNotices"
if [[ -d "$notices" ]]; then
    chmod -R u+w "$notices"
    rm -r "$notices"
fi
mkdir -p "$notices"
cp LICENSE "$notices/ALO-MIT.txt"
cp Vendor/DynamicNotch/LICENSE "$notices/DynamicNotch-GPL-3.0.txt"
cp Vendor/DynamicNotch/DynamicNotch/Resources/MediaRemoteAdapter/LICENSE "$notices/MediaRemoteAdapter-BSD-3-Clause.txt"
cp Vendor/README.md "$notices/DynamicNotch-provenance.md"
for dependency_notice in .build/checkouts/*/LICENSE*(N.) .build/checkouts/*/COPYING*(N.); do
    dependency_directory="${dependency_notice:h}"
    cp "$dependency_notice" "$notices/${dependency_directory:t}-${dependency_notice:t}"
done
cat > "$notices/README.txt" <<'NOTICE'
ALO includes original and adapted DynamicNotch code under GNU GPL version 3.
The ALO MIT notice does not replace the terms of the imported DynamicNotch code.
MediaRemoteAdapter is distributed under its accompanying BSD 3-Clause license.
Original copyright notices and license texts are retained with the source.

ALO and adapted notch source, build scripts, and dependency manifests:
https://github.com/theShyamsindhia/WERAI
Use the source revision or release tag corresponding to this application build.
The notch runtime source is in Vendor/DynamicNotch and ALO adapters are in
Sources/ALO. Upstream: https://github.com/jackson-storm/DynamicNotch
NOTICE

if [[ ${#architectures[@]} -eq 1 ]]; then
    cp ".build/${architectures[1]}-apple-macosx/release/alo" "$binary"
else
    lipo -create \
        .build/arm64-apple-macosx/release/alo \
        .build/x86_64-apple-macosx/release/alo \
        -output "$binary"
fi
# Keep symbols outside the distributed app/CLI, then strip only debug and local
# symbols. Exported symbols and Swift runtime reflection metadata remain intact.
# This substantially reduces the embedded feature engine's LINKEDIT footprint.
dsymutil "$binary" -o "$binary.dSYM"
strip -S -x "$binary"

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
for packaged_resource_bundle in "${resource_bundles[@]}"; do
    ditto "$packaged_resource_bundle" "$app/Contents/Resources/${packaged_resource_bundle:t}"
done
ditto "$notices" "$app/Contents/Resources/ThirdPartyNotices"
if $development_build; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ALO Dev" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ALO Dev" "$app/Contents/Info.plist"
fi
cp dist/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
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
"$app/Contents/MacOS/alo" verify-game-resources

if $development_build; then
    echo "Created $app with isolated bundle id $bundle_identifier"
    exit 0
fi

rm -f "$cli_archive"
cli_staging="$(mktemp -d "${TMPDIR:-/tmp}/alo-cli-distribution.XXXXXX")"
trap 'rm -rf "$cli_staging"' EXIT
cp "$binary" "$cli_staging/alo"
for packaged_resource_bundle in "${resource_bundles[@]}"; do
    ditto "$packaged_resource_bundle" "$cli_staging/${packaged_resource_bundle:t}"
done
ditto "$notices" "$cli_staging/ThirdPartyNotices"
ditto -c -k "$cli_staging" "$cli_archive"
./Scripts/create_distribution_archives.sh "$archive_suffix"

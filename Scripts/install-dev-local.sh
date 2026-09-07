#!/bin/bash
# Local-only dev installation. Never uses a signing identity, modifies release
# ALO, strips the linked executable, or touches either app's user data.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
    echo "Usage: bash Scripts/install-dev-local.sh [--skip-build]" >&2
    exit 2
fi
if ps -axo comm= | grep -Eq '^/Applications/(ALO|ALO Dev)\.app/Contents/MacOS/alo$'; then
    echo "Quit both ALO and ALO Dev before installing the dev build." >&2
    exit 1
fi
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build -c release
fi
build_dir="$(swift build -c release --show-bin-path)"
test -x "$build_dir/alo"
stage_dir="$(mktemp -d /tmp/alo-dev-install.XXXXXX)"
staged_app="$stage_dir/ALO Dev.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$build_dir/alo" "$staged_app/Contents/MacOS/alo"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
for resource in "$build_dir"/*.bundle; do
    test -d "$resource"
    ditto "$resource" "$staged_app/Contents/Resources/$(basename "$resource")"
done
cp Resources/ALOSetupBackground.png "$staged_app/Contents/Resources/"
for slide in Resources/ALOSetupSlide-*.jpg; do
    cp "$slide" "$staged_app/Contents/Resources/"
done
# Reuse the repository's packaged icon; icon generation is not part of this
# diagnostic install and must not change the binary's linker-generated seal.
if [[ -f dist/AppIcon.icns ]]; then
    cp dist/AppIcon.icns "$staged_app/Contents/Resources/"
fi
plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier in.werai.audio.dev' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName ALO Dev' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName ALO Dev' "$plist"
/usr/libexec/PlistBuddy -c "Add :ALODevelopmentRevision string $(git rev-parse HEAD)" "$plist"
/usr/libexec/PlistBuddy -c "Add :ALODevelopmentBinarySHA256 string $(shasum -a 256 "$build_dir/alo" | cut -d ' ' -f 1)" "$plist"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :ALODevelopmentDirty bool true' "$plist"
fi
"$staged_app/Contents/MacOS/alo" verify-game-resources
"$staged_app/Contents/MacOS/alo" verify-network-configuration

destination='/Applications/ALO Dev.app'
if [[ -e "$destination" ]]; then
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")" = 'in.werai.audio.dev'
    backup_dir="$(mktemp -d /Applications/alo-dev-backup.XXXXXX)"
    mv "$destination" "$backup_dir/ALO Dev.app"
    echo "Previous dev app preserved at: $backup_dir/ALO Dev.app"
fi
mv "$staged_app" "$destination"
echo "Installed: $destination"
echo "Source: $(git rev-parse HEAD)"
echo "No signing command was run. macOS may request dev-app permissions."
echo "Staging directory retained: $stage_dir"

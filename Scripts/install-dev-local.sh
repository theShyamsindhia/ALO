#!/bin/bash
# Local-only dev installation. Uses certificate-free ad-hoc signing; never modifies release
# ALO, strips the linked executable, or migrates user data. Some optional game
# and icon stores are shared at runtime; exclude those from isolated dev tests.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
    echo "Usage: bash Scripts/install-dev-local.sh [--skip-build]" >&2
    exit 2
fi
if ps -axww -o comm= | grep -E '/(ALO|ALO Dev)\.app/Contents/MacOS/alo$' > /dev/null; then
    echo "Quit both ALO and ALO Dev before installing the dev build." >&2
    exit 1
fi
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build -c release
fi
build_dir="$(swift build -c release --show-bin-path)"
test -x "$build_dir/alo"
stage_dir="$(mktemp -d /tmp/alo-dev-install.XXXXXX)"
trap 'if [[ -d "$stage_dir" ]]; then echo "Dev staging files retained at: $stage_dir" >&2; fi' EXIT
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
# diagnostic install. Seal the completed app below, after all resources/plist edits.
if [[ -f dist/AppIcon.icns ]]; then
    cp dist/AppIcon.icns "$staged_app/Contents/Resources/"
fi
plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier in.werai.audio.dev' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName ALO Dev' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName ALO Dev' "$plist"
/usr/libexec/PlistBuddy -c "Add :ALODevelopmentRevision string $(git rev-parse HEAD)" "$plist"
/usr/libexec/PlistBuddy -c "Add :ALODevelopmentInputBinarySHA256 string $(shasum -a 256 "$build_dir/alo" | cut -d ' ' -f 1)" "$plist"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :ALODevelopmentDirty bool true' "$plist"
fi
"$staged_app/Contents/MacOS/alo" verify-game-resources
"$staged_app/Contents/MacOS/alo" verify-network-configuration
codesign --force --sign - --timestamp=none --identifier in.werai.audio.dev "$staged_app"
codesign --verify --deep --strict "$staged_app"

destination='/Applications/ALO Dev.app'
if [[ -e "$destination" ]]; then
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")" = 'in.werai.audio.dev'
    backup_root="${HOME}/Library/Application Support/ALO Dev Backups"
    mkdir -p "$backup_root"
    backup_dir="$(mktemp -d "$backup_root/backup.XXXXXX")"
    mv "$destination" "$backup_dir/ALO Dev.app"
    echo "Previous dev app preserved at: $backup_dir/ALO Dev.app"
fi
mv "$staged_app" "$destination"
echo "Installed: $destination"
echo "Source: $(git rev-parse HEAD)"
echo "Ad-hoc signed without a certificate. macOS may request dev-app permissions or first-open approval."
shasum -a 256 "$destination/Contents/MacOS/alo"
rmdir "$stage_dir" 2>/dev/null || true

#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
icon_test_dir="$(mktemp -d /tmp/alo-icon-test.XXXXXX)"
trap 'rm -rf -- "$icon_test_dir"' EXIT
master="$repo_root/Resources/ALOLogo-1024.png"
if [[ $# -eq 2 && "$1" == "--verify" ]]; then
    icon="$2"
elif [[ $# -eq 0 ]]; then
    icon="$icon_test_dir/AppIcon.icns"
    bash "$repo_root/Scripts/build-app-icon.sh" "$icon"
    before="$(shasum -a 256 "$icon")"
    if bash "$repo_root/Scripts/build-app-icon.sh" "$icon" "$icon_test_dir/missing.png"; then
        echo "Missing master was incorrectly accepted" >&2
        exit 1
    fi
    test "$before" = "$(shasum -a 256 "$icon")"
else
    echo "Usage: bash Scripts/test-app-icon.sh [--verify ICON_ICNS]" >&2
    exit 2
fi
test -s "$icon"
iconutil -c iconset "$icon" -o "$icon_test_dir/decoded.iconset"
for name in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    test -s "$icon_test_dir/decoded.iconset/$name"
done
osascript -l JavaScript "$repo_root/Scripts/verify-app-icon.js" \
    "$icon_test_dir/decoded.iconset/icon_512x512@2x.png" "$master"

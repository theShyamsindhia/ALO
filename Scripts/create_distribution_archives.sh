#!/bin/zsh

set -euo pipefail

cd "${0:A:h}/.."

archive_suffix="${1:-}"
if [[ "$archive_suffix" != "arm64" && "$archive_suffix" != "universal" ]]; then
    echo "Usage: $0 <arm64|universal>" >&2
    exit 2
fi

app="dist/ALO.app"
zip_archive="dist/ALO-macos-$archive_suffix.zip"
dmg_archive="dist/ALO-macos-$archive_suffix.dmg"
test -d "$app"

rm -f "$zip_archive" "$dmg_archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_archive"

dmg_staging="$(mktemp -d "${TMPDIR:-/tmp}/werai-dmg.XXXXXX")"
cleanup() {
    rm -rf "$dmg_staging"
}
trap cleanup EXIT

ditto "$app" "$dmg_staging/ALO.app"
if [[ -f dist/Install-ALO-Audio-Device.pkg ]]; then
    cp dist/Install-ALO-Audio-Device.pkg "$dmg_staging/Install ALO Audio Device.pkg"
fi
ln -s /Applications "$dmg_staging/Applications"
hdiutil create \
    -volname ALO \
    -srcfolder "$dmg_staging" \
    -ov \
    -format UDZO \
    "$dmg_archive" >/dev/null

echo "Created $zip_archive"
echo "Created $dmg_archive"

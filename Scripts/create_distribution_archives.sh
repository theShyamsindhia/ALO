#!/bin/zsh

set -euo pipefail

cd "${0:A:h}/.."

archive_suffix="${1:-}"
if [[ "$archive_suffix" != "arm64" && "$archive_suffix" != "universal" ]]; then
    echo "Usage: $0 <arm64|universal>" >&2
    exit 2
fi

app="dist/WERAI.app"
zip_archive="dist/WERAI-macos-$archive_suffix.zip"
dmg_archive="dist/WERAI-macos-$archive_suffix.dmg"
test -d "$app"

rm -f "$zip_archive" "$dmg_archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_archive"

dmg_staging="$(mktemp -d "${TMPDIR:-/tmp}/werai-dmg.XXXXXX")"
cleanup() {
    rm -rf "$dmg_staging"
}
trap cleanup EXIT

ditto "$app" "$dmg_staging/WERAI.app"
ln -s /Applications "$dmg_staging/Applications"
hdiutil create \
    -volname WERAI \
    -srcfolder "$dmg_staging" \
    -ov \
    -format UDZO \
    "$dmg_archive" >/dev/null

echo "Created $zip_archive"
echo "Created $dmg_archive"

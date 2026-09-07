#!/bin/bash
# Generate packaging resources from the checked-in master, never stale dist output.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || "$1" != *.icns ]]; then
    echo "Usage: bash Scripts/build-app-icon.sh OUTPUT_ICNS [MASTER_PNG]" >&2
    exit 2
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_icon="$1"
icon_master="${2:-$repo_root/Resources/ALOLogo-1024.png}"
if [[ ! -f "$icon_master" ]]; then
    echo "Required app icon master is missing: $icon_master" >&2
    exit 1
fi
dimensions="$(sips -g pixelWidth -g pixelHeight "$icon_master")"
test "$(awk '/pixelWidth:/ {print $2}' <<< "$dimensions")" = 1024
test "$(awk '/pixelHeight:/ {print $2}' <<< "$dimensions")" = 1024
icon_work_dir="$(mktemp -d /tmp/alo-app-icon.XXXXXX)"
trap 'rm -rf -- "$icon_work_dir"' EXIT
iconset="$icon_work_dir/AppIcon.iconset"
mkdir "$iconset"
for specification in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    size=${specification%% *}
    name=${specification#* }
    sips -z "$size" "$size" "$icon_master" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o "$icon_work_dir/AppIcon.icns"
test -s "$icon_work_dir/AppIcon.icns"
mkdir -p "$(dirname "$output_icon")"
mv "$icon_work_dir/AppIcon.icns" "$output_icon"
echo "Generated app icon: $output_icon"

#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h}/.."
driver_root="$repo_root/AudioDriver"
bundle="$repo_root/dist/ALORoom.driver"
binary="$bundle/Contents/MacOS/ALORoom"
identity="${ALO_CODESIGN_IDENTITY:-${WERAI_CODESIGN_IDENTITY:--}}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
architectures=(arm64 x86_64)
if [[ "${1:-}" == "--arm64-only" ]]; then
  architectures=(arm64)
elif [[ "${1:-}" == "--x86_64-only" ]]; then
  architectures=(x86_64)
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--arm64-only|--x86_64-only]" >&2
  exit 2
fi

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$driver_root/Resources/Info.plist" "$bundle/Contents/Info.plist"

thin_binaries=()
for architecture in "${architectures[@]}"; do
  thin_binary="${TMPDIR:-/tmp}/alo-room-driver-$architecture-$$"
  thin_binaries+=("$thin_binary")
  xcrun clang -std=c11 -O2 -fblocks -arch "$architecture" \
    -mmacosx-version-min=14.0 -isysroot "$sdk" -dynamiclib \
    -I "$driver_root/include" -I "$driver_root/Sources" \
    "$driver_root/Sources/WERAIAudioDriver.c" \
    "$driver_root/Sources/WERAILoopbackRing.c" \
    "$driver_root/Sources/WERAISharedAudio.c" \
    -framework CoreAudio -framework CoreFoundation -o "$thin_binary" \
    -Wl,-exported_symbol,_WERAIAudioDriver_Create
done
trap 'rm -f "${thin_binaries[@]}"' EXIT
if [[ ${#thin_binaries[@]} -eq 1 ]]; then
  cp "$thin_binaries[1]" "$binary"
else
  lipo -create "${thin_binaries[@]}" -output "$binary"
fi

codesign_args=(--force --sign "$identity" --identifier in.werai.audio.driver)
if [[ "$identity" != "-" ]]; then
  codesign_args+=(--options runtime --timestamp)
  signing_keychain="${ALO_SIGNING_KEYCHAIN:-${WERAI_SIGNING_KEYCHAIN:-}}"
  [[ -n "$signing_keychain" ]] && codesign_args+=(--keychain "$signing_keychain")
fi
codesign "${codesign_args[@]}" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
echo "Built $bundle"

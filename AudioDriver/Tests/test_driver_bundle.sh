#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h}/../.."
"$repo_root/Scripts/build_audio_driver.sh"
bundle="$repo_root/dist/ALORoom.driver"
binary="$bundle/Contents/MacOS/ALORoom"
test_binary="${TMPDIR:-/tmp}/werai-ring-test-$$"
client_test_binary="${TMPDIR:-/tmp}/werai-client-abi-test-$$"
trap 'rm -f "$test_binary" "$client_test_binary"' EXIT

test "$(plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist")" = "in.werai.audio.driver"
test "$(plutil -extract CFBundleName raw "$bundle/Contents/Info.plist")" = "ALO Room"
plutil -extract CFPlugInTypes.443ABAB8-E7B3-491A-B985-BEB9187030DB xml1 -o - "$bundle/Contents/Info.plist" | grep -q 57F1A389-8B0D-4D61-A627-8B72A56F5D6E
symbols="$(nm -gj "$binary")"
grep -qx _WERAIAudioDriver_Create <<< "$symbols"
codesign --verify --strict "$bundle"
file "$binary" | grep -q 'Mach-O universal binary'
lipo "$binary" -verify_arch arm64 x86_64

xcrun clang -std=c11 -O2 \
  -I "$repo_root/AudioDriver/include" -I "$repo_root/AudioDriver/Sources" \
  "$repo_root/AudioDriver/Tests/ring_test.c" \
  "$repo_root/AudioDriver/Sources/WERAILoopbackRing.c" \
  "$repo_root/AudioDriver/Sources/WERAISharedAudio.c" \
  -o "$test_binary"
"$test_binary"

xcrun clang -std=c11 -O2 \
  -I "$repo_root/AudioDriver/include" \
  -I "$repo_root/Sources/WERAISharedAudioClient/include" \
  "$repo_root/AudioDriver/Tests/client_abi_test.c" \
  "$repo_root/AudioDriver/Sources/WERAISharedAudio.c" \
  "$repo_root/Sources/WERAISharedAudioClient/WERAISharedAudioClient.c" \
  -o "$client_test_binary"
"$client_test_binary"

if tail -n 110 "$repo_root/AudioDriver/Sources/WERAIAudioDriver.c" | \
  grep -Eq '(malloc|calloc|realloc|printf|syslog|pthread_mutex_[a-z]+|AudioObject(Get|Set|Add|Remove))[[:space:]]*\('; then
  echo "Forbidden real-time operation found in DoIOOperation" >&2
  exit 1
fi
echo "driver bundle contract passed"

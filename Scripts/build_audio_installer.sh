#!/bin/zsh

set -euo pipefail

cd "${0:A:h}/.."

driver="dist/ALORoom.driver"
payload_root="dist/audio-installer-root"
package="dist/Install-ALO-Audio-Device.pkg"
installer_identity="${ALO_INSTALLER_IDENTITY:-${WERAI_INSTALLER_IDENTITY:-}}"

./Scripts/build_audio_driver.sh

rm -rf "$payload_root"
mkdir -p "$payload_root/Library/Audio/Plug-Ins/HAL"
ditto "$driver" "$payload_root/Library/Audio/Plug-Ins/HAL/ALORoom.driver"
/bin/chmod -R go-w "$payload_root"

arguments=(
    --root "$payload_root"
    --identifier in.werai.audio.driver.pkg
    --version 1.0.0
    --install-location /
    --ownership recommended
    --scripts AudioDriver/InstallerScripts
)
if [[ -n "$installer_identity" ]]; then
    arguments+=(--sign "$installer_identity")
    signing_keychain="${ALO_SIGNING_KEYCHAIN:-${WERAI_SIGNING_KEYCHAIN:-}}"
    [[ -n "$signing_keychain" ]] && arguments+=(--keychain "$signing_keychain")
fi

rm -f "$package"
pkgbuild "${arguments[@]}" "$package"
pkgutil --payload-files "$package" | grep -Fq './Library/Audio/Plug-Ins/HAL/ALORoom.driver/Contents/MacOS/ALORoom'

if [[ -n "$installer_identity" ]]; then
    pkgutil --check-signature "$package" | grep -Fq 'Developer ID Installer'
fi

echo "Built $package"

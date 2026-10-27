#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Everything is built and packaged locally. No GitHub Actions or account data.
LIBRE_ARCHS='arm64 x86_64' bash scripts/build.sh
APP="$PWD/build/Libre Desktop.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
release_dir="$PWD/build/releases/$version"
staging=$(mktemp -d "$PWD/build/release-stage.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$release_dir"
name="Libre-Desktop-$version-universal"

ditto "$APP" "$staging/Libre Desktop.app"
ln -s /Applications "$staging/Applications"
cp docs/INSTALL.txt "$staging/Start Here.txt"
hdiutil create -volname 'Libre Desktop' -srcfolder "$staging" -format UDZO -ov "$release_dir/$name.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$release_dir/$name.zip"
cp docs/INSTALL.txt "$release_dir/INSTALL.txt"
(
    cd "$release_dir"
    shasum -a 256 "$name.dmg" "$name.zip" INSTALL.txt > SHA256SUMS.txt
)
printf 'Release files: %s\n' "$release_dir"

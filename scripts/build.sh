#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/Libre Desktop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" build/bin
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LibreDesktop</string>
<key>CFBundleIdentifier</key><string>local.shiv.libredesktop</string>
<key>CFBundleName</key><string>Libre Desktop</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHumanReadableCopyright</key><string>Libre Desktop contributors. AGPL-3.0.</string>
</dict></plist>
PLIST

swift scripts/generate-libre-icon.swift "$PWD/build/LibreIcon.iconset"
iconutil -c icns "$PWD/build/LibreIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
executables=()
for architecture in ${LIBRE_ARCHS:-$(uname -m)}; do
    case "$architecture" in
        arm64|x86_64) ;;
        *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
    esac
    executable="$PWD/build/bin/LibreDesktop-$architecture"
    swiftc -swift-version 5 -O -target "$architecture-apple-macosx14.0" \
        Sources/LibreDesktop/*.swift -o "$executable" \
        -framework AppKit -framework SwiftUI -framework Charts -framework Security
    executables+=("$executable")
done
lipo -create "${executables[@]}" -output "$APP/Contents/MacOS/LibreDesktop"
cp LICENSE THIRD_PARTY.md README.md "$APP/Contents/Resources/Licenses/"

# A local build needs no account, certificates, Python, or downloaded tools.
# Maintainers can supply an identity already present in their own Keychain.
identity="${LIBRE_SIGNING_IDENTITY:--}"
if [ "$identity" = '-' ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$APP"
fi
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"

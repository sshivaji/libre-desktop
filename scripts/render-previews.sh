#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/previews
sources=()
for source in Sources/LibreDesktop/*.swift; do
    if [ "$(basename "$source")" != 'main.swift' ]; then sources+=("$source"); fi
done
swiftc -swift-version 5 "${sources[@]}" scripts/render-libre.swift \
    -o build/render-previews -framework AppKit -framework SwiftUI -framework Charts -framework Security
# The renderer does not call start(), restore Keychain accounts, or fetch data.
build/render-previews "$PWD/build/previews"

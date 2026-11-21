#!/bin/zsh
# Regenerates docs/screenshots/*.png from the app's real SwiftUI views.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    Sources/ContentView.swift Sources/FileStore.swift Sources/ConversionEngine.swift Tools/Screenshots.swift \
    -o "$TMP/screenshots"
"$TMP/screenshots" docs/screenshots "$TMP/demo"

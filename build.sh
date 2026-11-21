#!/bin/zsh
# Builds "The Converter.app" and installs it into ~/Applications, then registers
# the Finder right-click action.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="The Converter"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/TheConverter"

cp Info.plist "$APP/Contents/Info.plist"

echo "Making icon…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift Tools/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"

echo "Installing to $INSTALL_DIR…"
mkdir -p "$INSTALL_DIR"
pkill -x TheConverter 2>/dev/null || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Remove the build copy so macOS only sees the installed app (otherwise it shows up twice).
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP" "$ICONSET"
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "Done. Right-click a file in Finder › Quick Actions (or Services) › Convert with The Converter"

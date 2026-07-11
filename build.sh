#!/bin/bash
# Baut RoundDrop.app – benötigt nur die Xcode-Kommandozeilenwerkzeuge.
set -euo pipefail
cd "$(dirname "$0")"

APP="RoundDrop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
cp icon.icns "$APP/Contents/Resources/icon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
SRCS="Sources/main.swift"

swiftc -O -sdk "$SDK" -target arm64-apple-macos13.0  -o /tmp/RoundDrop_arm64   $SRCS
swiftc -O -sdk "$SDK" -target x86_64-apple-macos13.0 -o /tmp/RoundDrop_x86_64  $SRCS
lipo -create /tmp/RoundDrop_arm64 /tmp/RoundDrop_x86_64 -output "$APP/Contents/MacOS/RoundDrop"

SIGN_ID="Developer ID Application: aketo GmbH (9H7F5NMT97)"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/RoundDrop"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
echo "Fertig: $(pwd)/$APP"

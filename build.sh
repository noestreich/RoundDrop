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

swiftc -O -o "$APP/Contents/MacOS/RoundDrop" Sources/main.swift

codesign --force --sign - "$APP"
echo "Fertig: $(pwd)/$APP"

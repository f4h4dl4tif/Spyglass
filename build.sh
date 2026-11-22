#!/bin/bash
# Builds Spyglass.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

# The macOS 27 SDK in Command Line Tools lacks the SwiftUI macro plugin (@State etc.),
# so build against the 26.5 SDK when no SDK is chosen explicitly.
if [ -z "${SDKROOT:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Spyglass
else
  swift build -c release
  BIN=.build/release/Spyglass
fi

ICON=Resources/AppIcon.icns
if [ ! -f "$ICON" ]; then
  TMP=$(mktemp -d)
  swift Scripts/make-icon.swift "$TMP/icon.png"
  SET="$TMP/AppIcon.iconset"; mkdir "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON"
  rm -rf "$TMP"
fi

APP=build/Spyglass.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spyglass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
Scripts/intents-metadata.sh "$APP" 2>&1 | grep -v "appintentsmetadataprocessor\[" || true
strip -rSTx "$APP/Contents/MacOS/Spyglass" 2>/dev/null || strip -x "$APP/Contents/MacOS/Spyglass"

# Sign with a stable local certificate so macOS permissions (camera, calendars,
# screen recording, automation) survive rebuilds. Falls back to ad-hoc signing.
KC="$(pwd)/signing/spyglass.keychain-db"
if [ -f "$KC" ] && [ -f signing/keychain-password.txt ]; then
  security unlock-keychain -p "$(cat signing/keychain-password.txt)" "$KC"
  ID=$(security find-identity "$KC" | awk '/Spyglass Local Signing/ {print $2; exit}')
  codesign --force --deep --keychain "$KC" --sign "$ID" -i local.spyglass.Spyglass "$APP"
  echo "Signed with Spyglass Local Signing ($ID)"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "Warning: ad-hoc signed; permissions will reset on every rebuild (run Scripts/make-signing.sh once)"
fi

echo "Built $(pwd)/$APP"

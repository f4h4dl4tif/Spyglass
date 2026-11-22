#!/bin/bash
# Generates App Intents metadata (Shortcuts + Siri actions) into the app bundle, the same step Xcode runs.
# Usage: Scripts/intents-metadata.sh build/Spyglass.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"
XC=/Applications/Xcode.app/Contents/Developer
TC="$XC/Toolchains/XcodeDefault.xctoolchain"
TOOL="$TC/usr/bin/appintentsmetadataprocessor"
[ -x "$TOOL" ] || { echo "Xcode not found; skipping Shortcuts metadata"; exit 0; }
CONSTS=.build/Spyglass.swiftconstvalues
[ -f "$CONSTS" ] || { echo "No const values; build with -c release first"; exit 1; }
SDK=$(DEVELOPER_DIR="$XC" xcrun --sdk macosx --show-sdk-path)
XCV=$(DEVELOPER_DIR="$XC" xcodebuild -version | awk '/Build version/ {print $3}')
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
find "$(pwd)/Sources/Spyglass" -name '*.swift' > "$W/sources.txt"
echo "$(pwd)/$CONSTS" > "$W/consts.txt"
: > "$W/meta.txt"; : > "$W/static.txt"
"$TOOL" --toolchain-dir "$TC" --module-name Spyglass --sdk-root "$SDK" --xcode-version "$XCV" \
  --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
  --output "$APP/Contents/Resources" --source-file-list "$W/sources.txt" --swift-const-vals-list "$W/consts.txt" \
  --metadata-file-list "$W/meta.txt" --static-metadata-file-list "$W/static.txt" \
  --dependency-file "$W/deps" --stringsdata-file "$W/strings.stringsdata" \
  --deployment-aware-processing --no-app-shortcuts-localization --force
ls "$APP/Contents/Resources/Metadata.appintents" >/dev/null && echo "App Intents metadata added"

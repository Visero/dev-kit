#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.staging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/DevKit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/DevKit" \
  -framework SwiftUI -framework AppKit
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/DevKit.icns" ]]; then
  cp "$ROOT/Resources/DevKit.icns" "$APP/Contents/Resources/"
fi
# Precompiled Icon Composer catalog supplies native Default/Dark appearances.
# Keep the legacy icns as a fallback on older macOS versions.
test -s "$ROOT/Resources/Assets.car"
cp "$ROOT/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"
# Keep the prior bundle intact. Never overwrite a running signed bundle in place.
if [[ -d "$OUT/DevKit.app" ]]; then
  BACKUP="$(mktemp -d "$OUT/.previous.XXXXXX")"
  mv "$OUT/DevKit.app" "$BACKUP/DevKit.app"
fi
mv "$APP" "$OUT/DevKit.app"
printf 'Built: %s\n' "$OUT/DevKit.app"

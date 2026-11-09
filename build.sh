#!/bin/bash
# DevKit build & packaging script.
#   bash build.sh            -> compile, bundle, sign, verify, refresh build/DevKit.app
#   bash build.sh package    -> same, then emit DevKit-<ver>-macOS-arm64.zip and
#                               DevKit-<ver>-source.zip next to this script.
# Only the staging copy is moved into place after every step succeeds; the prior
# bundle is never overwritten in place.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
VERSION="1.6.2"
BUILD="12"
ARCH="arm64"
TARGET="arm64-apple-macosx14.0"

mkdir -p "$OUT"
# NOTE: cleanup is limited to build/ staging/temp dirs. It never touches the
# user's App Support private drafts (~/Library/Application Support), which are
# user real content and must not be swept into archives or deleted.
STAGE="$(mktemp -d "$OUT/.staging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/DevKit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- 1. Compile -----------------------------------------------------------
xcrun swiftc -swift-version 5 -O -target "$TARGET" \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/DevKit" \
  -framework SwiftUI -framework AppKit

# --- 2. Bundle metadata & icon resources ----------------------------------
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# Precompiled Icon Composer catalog supplies native Default/Dark appearances.
test -s "$ROOT/Resources/Assets.car"
cp "$ROOT/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
if [[ -f "$ROOT/Resources/DevKit.icns" ]]; then
  cp "$ROOT/Resources/DevKit.icns" "$APP/Contents/Resources/"
fi

# --- 3. Embed offline formatter engines (web runtimes + native Mach-O) ----
# Resources/Formatters carries its own LICENSE/manifest; the whole tree is
# copied verbatim so the app is fully offline and self-contained.
if [[ -d "$ROOT/Resources/Formatters" ]]; then
  mkdir -p "$APP/Contents/Resources/Formatters"
  cp -R "$ROOT/Resources/Formatters/." "$APP/Contents/Resources/Formatters/"
fi

# --- 4. Sign inner Mach-O first, then the outer bundle ---------------------
# Strip quarantine/metadata so the zip is byte-clean and signed.
xattr -cr "$APP" 2>/dev/null || true
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    codesign --force --sign - "$f"
  fi
done < <(find "$APP" -type f -print0)
codesign --force --sign - "$APP"

# --- 5. Hard verification before anything moves ---------------------------
codesign --verify --strict --deep --verbose=2 "$APP" >/dev/null

# --- 6. Only now move the staged bundle into place -------------------------
# Keep the prior bundle intact; never overwrite a running signed bundle.
if [[ -d "$OUT/DevKit.app" ]]; then
  BACKUP="$(mktemp -d "$OUT/.previous.XXXXXX")"
  mv "$OUT/DevKit.app" "$BACKUP/DevKit.app"
fi
mv "$APP" "$OUT/DevKit.app"
trap - EXIT
printf 'Built: %s (version %s build %s)\n' "$OUT/DevKit.app" "$VERSION" "$BUILD"

# --- 7. Optional packaging -------------------------------------------------
if [[ "${1:-}" == "package" ]]; then
  APP_ZIP="$ROOT/DevKit-${VERSION}-macOS-${ARCH}.zip"
  SRC_ZIP="$ROOT/DevKit-${VERSION}-source.zip"
  for z in "$APP_ZIP" "$SRC_ZIP"; do
    if [[ -e "$z" ]]; then
      echo "Refusing to overwrite existing archive: $z" >&2
      exit 1
    fi
  done

  # App distribution: runnable DevKit.app + user README + engine licenses.
  PKG="$(mktemp -d "$OUT/.pkg.XXXXXX")"
  trap 'rm -rf "$PKG" "$STAGE"' EXIT
  cp -R "$OUT/DevKit.app" "$PKG/DevKit.app"
  cp "$ROOT/README.md" "$PKG/README.md"
  if [[ -d "$ROOT/Resources/Formatters/LICENSE" ]]; then
    mkdir -p "$PKG/LICENSE"
    cp -R "$ROOT/Resources/Formatters/LICENSE/." "$PKG/LICENSE/"
  elif [[ -f "$ROOT/Resources/Formatters/LICENSE" ]]; then
    cp "$ROOT/Resources/Formatters/LICENSE" "$PKG/LICENSE"
  fi
  # -y: preserve symlinks (JRE legal/* and node_modules/.bin are signed as
  # links; materializing them breaks the sealed-resource check after extract).
  (cd "$PKG" && COPYFILE_DISABLE=1 zip -r -X -y -q "$APP_ZIP" .)

  # Source distribution: complete source, tests, resources, scripts.
  # Explicit file list -> no build/, .git/, caches, DS_Store or agent records.
  SRC="$(mktemp -d "$OUT/.src.XXXXXX")"
  trap 'rm -rf "$PKG" "$SRC" "$STAGE"' EXIT
  DST="$SRC/DevKit"
  mkdir -p "$DST"
  cp "$ROOT/README.md" "$ROOT/Info.plist" "$ROOT/build.sh" "$ROOT/test.sh" "$ROOT/.gitignore" "$DST/"
  mkdir -p "$DST/Sources" "$DST/Tests"
  cp "$ROOT"/Sources/*.swift "$DST/Sources/"
  rsync -a --exclude '.DS_Store' "$ROOT/Tests/" "$DST/Tests/"
  rsync -a --exclude '.DS_Store' "$ROOT/Resources/" "$DST/Resources/"
  if [[ -d "$ROOT/ThirdPartySources" ]]; then
    mkdir -p "$DST/ThirdPartySources"
    rsync -a "$ROOT/ThirdPartySources/" "$DST/ThirdPartySources/"
  fi
  (cd "$SRC" && COPYFILE_DISABLE=1 zip -r -X -y -q "$SRC_ZIP" DevKit)

  printf 'Packaged:\n  %s\n  %s\n' "$APP_ZIP" "$SRC_ZIP"
fi

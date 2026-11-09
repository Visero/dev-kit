#!/bin/bash
# Static audit: offline, self-contained, no subprocess execution, no third-party deps.
# Run BEFORE the end-to-end GUI pass. Output is intended for the acceptance record.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Sources"

echo "== Sources scanned: =="
ls -1 "$SRC"/*.swift

echo
echo "== Network / upload probes (must be empty) =="
if grep -nE 'URLSession|URL\(string:|http://|https://|NSURLSession|downloadTask|uploadTask' \
     "$SRC"/*.swift || true; then
  echo "[note] grep above matches — review each hit before signing off."
fi

echo
echo "== Subprocess / exec probes (must be empty) =="
if grep -nE 'Process\(|launchPath|popen|system\(|/usr/bin/|/bin/bash|which ' \
     "$SRC"/*.swift || true; then
  echo "[note] grep above matches — review each hit before signing off."
fi

echo
echo "== Imports used (must be a fixed allowed set) =="
grep -hE '^import ' "$SRC"/*.swift | sort -u

echo
echo "== Built app codesign verification (if present) =="
if [[ -d "$ROOT/build/DevKit.app" ]]; then
  codesign --verify --strict --deep "$ROOT/build/DevKit.app" && \
    echo "codesign: OK" || echo "codesign: FAILED"
  codesign -dv --verbose=2 "$ROOT/build/DevKit.app" 2>&1 | head -20
else
  echo "build/DevKit.app not present — build it first via build.sh."
fi

echo
echo "== Zip artifact integrity (latest release) =="
LATEST_ZIP="$(ls -1t "$ROOT"/DevKit-*-macOS-arm64.zip 2>/dev/null | head -1 || true)"
if [[ -n "$LATEST_ZIP" ]]; then
  echo "latest: $LATEST_ZIP"
  unzip -tq "$LATEST_ZIP" 2>&1 | tail -20 || echo "unzip -t failed"
else
  echo "no release zip found under $ROOT"
fi

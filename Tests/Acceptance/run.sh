#!/bin/bash
# Independent acceptance runner. Compiles the runner against current Sources
# and either StubBackend (default) or RealBackend (when DEVKIT_REAL_BACKEND=1
# and Hooks/RealBackend.swift exists).
#
# Usage:
#   bash Tests/Acceptance/run.sh              # stub mode (works today)
#   DEVKIT_REAL_BACKEND=1 bash Tests/Acceptance/run.sh
#
# Never modifies Sources/, test.sh, build.sh, README, or Resources formatter assets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ACCEPT="$ROOT/Tests/Acceptance"
OUT="$ROOT/build"
mkdir -p "$OUT"

SOURCES=(
  "$ROOT/Sources/ToolCore.swift"
  "$ROOT/Sources/SyntaxCore.swift"
)
if [[ -f "$ROOT/Sources/CodeFormatting.swift" ]]; then
  SOURCES+=("$ROOT/Sources/CodeFormatting.swift")
fi

BACKEND_FILE="$ACCEPT/Hooks/StubBackend.swift"
declare -a FLAGS=()
if [[ "${DEVKIT_REAL_BACKEND:-0}" == "1" && -f "$ACCEPT/Hooks/RealBackend.swift" ]]; then
  BACKEND_FILE="$ACCEPT/Hooks/RealBackend.swift"
  FLAGS+=("-D" "DEVKIT_REAL_BACKEND")
  echo "== Using RealBackend (Hooks/RealBackend.swift) =="
else
  echo "== Using StubBackend (CodeFormatting not integrated; formatter gaps expected) =="
fi

BIN="$OUT/acceptance-runner"
echo "== Compiling $BIN =="
set -x
xcrun swiftc -swift-version 5 -O \
  ${FLAGS[@]+"${FLAGS[@]}"} \
  "${SOURCES[@]}" \
  "$ACCEPT/Hooks/FormatBackend.swift" \
  "$BACKEND_FILE" \
  "$ACCEPT/AcceptanceRunner.swift" \
  -o "$BIN"
set +x

echo "== Running =="
"$BIN"

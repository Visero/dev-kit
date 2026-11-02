#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
xcrun swiftc -swift-version 5 -O "$ROOT/Sources/ToolCore.swift" "$ROOT/Tests/CoreTests.swift" -o "$ROOT/build/core-tests"
"$ROOT/build/core-tests"

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
cd "$ROOT"

echo "=== Core tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/ToolCore.swift" "$ROOT/Sources/SyntaxCore.swift" "$ROOT/Tests/CoreTests.swift" \
  -o "$ROOT/build/core-tests"
"$ROOT/build/core-tests"

echo "=== Code formatting tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/ToolCore.swift" "$ROOT/Sources/SyntaxCore.swift" "$ROOT/Sources/CodeFormatting.swift" \
  "$ROOT/Tests/CodeFormattingTests.swift" \
  -o "$ROOT/build/code-formatting-tests"
"$ROOT/build/code-formatting-tests"

echo "=== Detection tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/ToolCore.swift" "$ROOT/Sources/SyntaxCore.swift" "$ROOT/Sources/CodeFormatting.swift" \
  "$ROOT/Tests/DetectionTests.swift" \
  -o "$ROOT/build/detection-tests"
"$ROOT/build/detection-tests"

echo "=== Native tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/ToolCore.swift" "$ROOT/Sources/SyntaxCore.swift" "$ROOT/Sources/SyntaxUI.swift" \
  "$ROOT/Sources/Components.swift" "$ROOT/Sources/CodeFormatting.swift" \
  "$ROOT/Tests/NativeTests.swift" \
  -framework SwiftUI -framework AppKit \
  -o "$ROOT/build/native-tests"
"$ROOT/build/native-tests"

echo "=== Draft persistence tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/CodeDraftStore.swift" \
  "$ROOT/Tests/DraftTests.swift" \
  -o "$ROOT/build/draft-tests"
"$ROOT/build/draft-tests"

echo "=== Native replacement/undo tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/SyntaxCore.swift" \
  "$ROOT/Tests/NativeReplacementTests.swift" \
  -framework AppKit \
  -o "$ROOT/build/native-replacement-tests"
"$ROOT/build/native-replacement-tests"

echo "=== Store integration tests ==="
xcrun swiftc -swift-version 5 -O -DBUILD_TEST \
  "$ROOT/Sources/ToolCore.swift" "$ROOT/Sources/SyntaxCore.swift" \
  "$ROOT/Sources/SyntaxUI.swift" "$ROOT/Sources/Components.swift" \
  "$ROOT/Sources/CodeFormatting.swift" "$ROOT/Sources/CodeDraftStore.swift" \
  "$ROOT/Sources/TextTools.swift" "$ROOT/Sources/TimeViews.swift" \
  "$ROOT/Sources/DevKitApp.swift" "$ROOT/Sources/NotebookStore.swift" \
  "$ROOT/Sources/MarkdownEditor.swift" "$ROOT/Sources/NotebookPage.swift" \
  "$ROOT/Sources/SyncCore.swift" "$ROOT/Sources/CloudSync.swift" \
  "$ROOT/Sources/CodeReaderCore.swift" "$ROOT/Sources/CodeReader.swift" \
  "$ROOT/Tests/StoreIntegrationTests.swift" \
  -framework SwiftUI -framework AppKit \
  -o "$ROOT/build/store-integration-tests"
"$ROOT/build/store-integration-tests"

echo "=== Sync merge / IO tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/ToolCore.swift" "$ROOT/Sources/SyntaxCore.swift" \
  "$ROOT/Sources/NotebookStore.swift" "$ROOT/Sources/SyncCore.swift" \
  "$ROOT/Tests/SyncTests.swift" \
  -framework AppKit \
  -o "$ROOT/build/sync-tests"
"$ROOT/build/sync-tests"

echo "=== Code reader tests ==="
xcrun swiftc -swift-version 5 -O \
  "$ROOT/Sources/ToolCore.swift" "$ROOT/Sources/SyntaxCore.swift" "$ROOT/Sources/SyntaxUI.swift" \
  "$ROOT/Sources/CodeReaderCore.swift" "$ROOT/Sources/CodeReader.swift" "$ROOT/Tests/CodeReaderTests.swift" \
  -framework SwiftUI -framework AppKit -o "$ROOT/build/code-reader-tests"
"$ROOT/build/code-reader-tests"

printf '\n=== Notebook / Markdown tests ===\n'
xcrun swiftc -swift-version 5 -O -DBUILD_TEST \
  "$ROOT"/Sources/*.swift "$ROOT/Tests/NotebookTests.swift" \
  -framework SwiftUI -framework AppKit -o "$ROOT/build/notebook-tests"
"$ROOT/build/notebook-tests"

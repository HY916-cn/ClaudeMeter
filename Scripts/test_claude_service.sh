#!/bin/bash
set -euo pipefail

# Run the production service/history against temporary SQLite and a fixture-only CLI.
TASK_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claudemeter-service-test.XXXXXX")"
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  TASK_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
TASK_SOURCES=()
while IFS= read -r -d '' TASK_SOURCE; do
  TASK_SOURCES+=("$TASK_SOURCE")
done < <(find "$TASK_PROJECT_DIR/CodexMeter/Core" -name '*.swift' ! -name 'ClaudeCLIClient.swift' -print0)
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -sdk "$TASK_SDK" -module-cache-path "$TASK_BUILD_DIR/module-cache" \
  "${TASK_SOURCES[@]}" \
  "$TASK_PROJECT_DIR/CodexMeter/UsageHistoryModel.swift" \
  "$TASK_PROJECT_DIR/CodexMeter/CodexUsageService.swift" \
  "$TASK_PROJECT_DIR/Tests/ClaudeServiceIntegration/main.swift" \
  -lsqlite3 -o "$TASK_BUILD_DIR/integration"
"$TASK_BUILD_DIR/integration"

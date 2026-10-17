#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/claude-recovery
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
  CodexMeter/Core/*.swift Tests/ClaudeRecoveryIntegration/main.swift \
  -lsqlite3 -o .build/claude-recovery/recovery-tests
.build/claude-recovery/recovery-tests

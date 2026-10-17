#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/claude-integration
swiftc -swift-version 5 -default-isolation MainActor -o .build/claude-integration/claude-tests \
  CodexMeter/Core/QuotaModels.swift \
  CodexMeter/Core/HistoryModels.swift \
  CodexMeter/Core/PopoverContentConfiguration.swift \
  CodexMeter/Core/CodexProcessSupport.swift \
  CodexMeter/Core/ClaudeUsageParser.swift \
  CodexMeter/Core/ClaudeCLIClient.swift \
  CodexMeter/Core/ClaudeRefreshSchedule.swift \
  Tests/ClaudeIntegration/main.swift
.build/claude-integration/claude-tests "$@"

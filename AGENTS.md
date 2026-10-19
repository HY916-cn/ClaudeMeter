# ClaudeMeter Development Guide

## Product and identity

ClaudeMeter is a native macOS 13+ menu bar app, derived from Raycal's
MIT-licensed CodexMeter (upstream 4c6baee, version 1.7.0). Preserve LICENSE and
upstream attribution. Current port version: 0.1.4, build 5.

- App product/display name: ClaudeMeter; bundle identifier: com.huang.ClaudeMeter.
- Keep internal CodexMeter source paths and core type names to make the fork
  easy to compare with upstream. The shared Xcode scheme is ClaudeMeter.
- Keep LSUIElement enabled and use native Apple frameworks. The app launches
  the locally installed Claude CLI, so the App Sandbox remains disabled.
- Store history under Application Support/ClaudeMeter, use .claudemeterbackup
  archives, and keep push credentials under com.huang.ClaudeMeter.pushCredentials.
- Updates use Sparkle 2.10.0, the repository's signed appcast.xml on raw GitHub,
  and this repository's GitHub Release assets. Preserve the dedicated public
  EdDSA key; the private key stays in login Keychain account com.huang.ClaudeMeter.
  Keep feed and pre-extraction archive signature verification enabled. Never
  reuse upstream signing keys or feeds. Automatic installation defaults off.
- Version 0.1.3 and earlier require one manual upgrade to 0.1.4. Verify updater
  download/install/relaunch with an isolated older-build copy; preserve user data.
  Upload working release assets before publishing the new signed feed.

## Source architecture and privacy

- CodexMeterApp.swift owns the shared service, settings, history, and windows.
- CodexUsageService.swift adapts installed Claude Code: account status comes
  from `claude auth status --json`; quota comes from interactive `/usage` via
  a bounded pseudo-terminal process. Core/Claude*.swift isolates the CLI
  discovery, process handling, and parser for tests.
- Claude owns authentication. Do not read auth files, extract access tokens,
  or add undocumented direct HTTP usage calls. Do not submit model prompts
  while collecting quota. Keep CLI tools and hooks disabled. Disable telemetry
  and error reporting individually; do not inject
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, which blocks usage queries in CLI 2.1.302.
- Require users to finish CLI setup and workspace trust themselves; do not
  auto-accept permission or trust prompts. Handle exit, timeout, malformed
  output, setup requirements, and sign-out explicitly.
- Keep the CLI child environment's PWD equal to its dedicated working directory;
  inherited workspace paths can stall startup from a desktop launch. Verify
  refreshes from the app launched through Launch Services as well as CLI tests.
- Terminal output is an unstable interface. Match only complete quota panels,
  bound process duration/output, drain output, stop child processes on failure,
  and show locally authored errors rather than raw CLI output.
- Do not persist raw CLI responses, authentication data, or account emails.
  Partition history using a salted pseudonymous account identity. Clear the
  previous account's visible state when login identity changes.
- On account activation, restore the last successful account-scoped history
  snapshot as stale, preserving its observation date. Never replace fresh CLI
  results with a delayed history read or evaluate alerts from restored data.
- Failed refreshes retain the last successful snapshot and mark it stale.
  Keep concurrent refreshes bounded and prevent duplicate requests.
- Poll every 5 minutes with the popover open and every 10 minutes in the
  background. Manual refreshes require 60 seconds between attempts and honor
  failure cooldowns. Cached or rate-limited responses back off for 5, 10, 20,
  then 30 minutes; show the retry time and preserve the last successful sample.
  Missing account identity permits live display only; do not persist history or deliver quota alerts for an unidentified account.
- Localizable.xcstrings contains English, Simplified Chinese, and Traditional
  Chinese UI strings. Keep source comments in English.

## UI and data invariants

- Preserve the configurable menu bar, popover, independent history window,
  settings, backup/restore, accessibility, notifications, and developer previews.
- Quota is `100 - usedPercent`, clamped to 0...100. Never fabricate zero use
  from missing data. Keep token counts and quota percentages separate.
- Only compute reset countdowns, time progress, and pace when duration and reset
  time are known. Keep each returned quota window independently selectable.
- Claude CLI /usage does not expose daily token history or banked resets.
  Preserve honest unavailable states; do not invent statistics or reset credits.
- Record successful non-stale changes and periodic 15-minute history anchors.
  Keep cycle boundaries, calendar browsing, explicit missing-data shading, raw
  sample persistence, and conservative consumption estimates intact.
- Preserve account-scoped CSV exports and all-account lossless backups.
  Backups must be transactionally consistent, size bounded, integrity checked,
  and recoverable after an interrupted restore. Restore replaces existing
  history and pauses further writes until the app restarts.
- Push channels default off, use HTTPS without redirects, store credentials
  in Keychain, redact diagnostics, and retain bounded retry/deduplication logic.
  Preview data must never send notifications or enter live history.
- Preference changes must preserve SwiftUI and host-window appearance behavior,
  menu-bar accessibility, and independent resizable history/settings windows.

## Verification and maintenance

Read the repository state before editing and keep changes scoped to the task.
Keep README.md and this file aligned with actual capabilities and known limits.
Do not claim a live authenticated refresh from fixture/parser tests alone.

```bash
swift test
bash Scripts/test_claude_cli.sh
bash Scripts/test_claude_recovery.sh
bash Scripts/test_claude_service.sh
bash Scripts/test_push_service.sh
bash Scripts/build_local.sh
git diff --check
xcodebuild -project CodexMeter.xcodeproj -scheme ClaudeMeter \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Use an installed full Xcode if xcodebuild is selected to Command Line Tools.
The local build script can use Swift 6.4 with the installed macOS 26.5 SDK,
Python 3, iconutil, and ad-hoc signing. macOS 27 SwiftUI macros require the
Xcode plugin. The CLI integration checks run without XCTest; the complete
upstream Swift Package test suite requires XCTest from Xcode.
The upstream project requires a recent Swift compiler and SDK (Xcode 27 beta
or later). Test login-item and notification behavior with a locally signed app.
UI changes require launching one app instance, opening its menu-bar popover,
and checking the affected controls. Real quota acceptance requires a signed-in
Claude subscription and a successful live /usage read. Keep push integration
checks isolated with fake credentials and URLProtocol; never contact real push
endpoints during tests.

Commit completed changes. Push major changes only to a repository for which
the user has authorized writes; an upstream fetch URL is attribution, not
permission to publish a fork there.

import Foundation
import Darwin

if CommandLine.arguments.contains("--check-working-directory") {
    let expected = URL(fileURLWithPath: CommandLine.arguments.last!).resolvingSymlinksInPath().path
    let actual = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
    let pwd = ProcessInfo.processInfo.environment["PWD"].map {
        URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
    }
    print(actual == expected && pwd == expected ? "directory-ok" : "directory-mismatch")
    exit(0)
}

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
let zone = TimeZone(identifier: "Asia/Singapore")!
let now = ISO8601DateFormatter().date(from: "2026-10-17T03:00:00Z")!
let panel = """
Current session
████████ 23% used
Resets 12pm (Asia/Singapore)

Current week (all models)
██████ 41% used
Resets Oct 20 at 11am (Asia/Singapore)

Current week (Sonnet only)
  92% remaining
Resets Oct 20 at 11am (Asia/Singapore)

Esc to cancel
"""
let windows = ClaudeUsageParser.parse(panel, now: now, timeZone: zone)!
expect(windows.count == 3, "All displayed usage windows are retained")
expect(windows.map(\.remainingPercent) == [77, 59, 92], "Used and remaining direction")
expect(windows[0].resetsAt == now.addingTimeInterval(3600), "Session time zone")
expect(windows[1].resetsAt == now.addingTimeInterval(3 * 86400), "Weekly date")
expect(windows[2].id == "claude-sonnet-only-secondary", "Scoped identity")
expect(ClaudeUsageParser.parse("Current session\n101% used\nEsc to cancel") == nil, "Reject invalid percentage")
expect(ClaudeUsageParser.parse("Current session\nUnknown\nCurrent week (all models)\n23% used\nEsc to cancel") == nil,
       "Do not borrow another window's percentage")
for heading in ["Extra usage", "Usage credits", "Claude Code and Cowork credit"] {
    expect(ClaudeUsageParser.parse("Current session\nUnknown\n\(heading)\n23% used\nEsc to cancel") == nil,
           "Do not borrow a credit section's percentage")
}
expect(ClaudeUsageParser.parse(panel + "\nCurrent session\nLoading usage…") == nil, "Reject incomplete repaint")
expect(ClaudeUsageParser.parse("Showing last-known usage\n" + panel) == nil, "Cached usage cannot be fresh")
expect(ClaudeUsageParser.blockingError(in: panel + "\nShowing last-known usage · 5m ago · r to retry") == .usageCached,
       "Cached CLI fallback has a distinct actionable error")
expect(ClaudeUsageParser.blockingError(in: "Usage endpoint is rate limited. Showing last-known usage") == .rateLimited,
       "Explicit rate limits take priority over cached fallback")
expect(ClaudeUsageParser.parse(panel + "\nUsage endpoint is rate limited") == nil,
       "Rate-limited data cannot enter history as a fresh sample")
let noReset = ClaudeUsageParser.parse("Current session\n0% used\nEsc to cancel")
expect(noReset?.first?.remainingPercent == 100 && noReset?.first?.resetsAt == nil, "Missing resets stay unknown")
expect(QuotaWindowSelection.preferredDefault(from: windows.reversed())?.id == "claude-secondary",
       "History defaults to all-model weekly quota")
expect(PopoverContentConfiguration.defaultValue.visibleQuotaWindows(from: windows).count == 3,
       "All Claude quota scopes are visible by default")
expect(ClaudeUsageParser.resetDate("nonsense", now: now, timeZone: zone, durationMinutes: 300) == nil,
       "Unknown reset stays unknown")
expect(ClaudeUsageParser.resetDate("10am (Asia/Singapore)", now: now, timeZone: zone, durationMinutes: 300) == nil,
       "Do not guess a reset beyond its window")
expect(ClaudeUsageParser.resetDate("12pm (Unknown/Zone)", now: now, timeZone: zone, durationMinutes: 300) == nil,
       "Unknown time zone stays unknown")
expect(ClaudeUsageParser.parse("\u{1B}[2J\u{1B}[32m" + panel + "\u{1B}[0m", now: now, timeZone: zone) == windows,
       "ANSI escapes do not affect quota")
expect(ClaudeUsageParser.blockingError(in: "Do you trust the files in this folder?") == .setupRequired,
       "Trust prompt never accepted")
expect(ClaudeUsageParser.blockingError(in: "Choose the text style that looks best") == .setupRequired,
       "Onboarding never accepted")
expect(ClaudeUsageParser.parse("Current session\n20% used\nCurrent wee") == nil, "Truncated panel cannot become fresh")
expect(ClaudeUsageParser.parse(panel.replacingOccurrences(of: "Esc to cancel", with: "Refreshing…\nEsc to cancel")) == nil,
       "Seeded panel still refreshing cannot become fresh")
// Claude 2.1.302 clears the final two rows after its network request succeeds.
// The screen-reader transcript does not repeat the quota headings on this repaint.
let refreshingPanel = panel.replacingOccurrences(of: "Esc to cancel", with: "Refreshing…\nEsc to cancel")
let completedRepaint = refreshingPanel + "\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[GEsc to cancel"
expect(ClaudeUsageParser.parse(completedRepaint, now: now, timeZone: zone) == windows,
       "Erasing Refreshing after a successful request makes the final complete screen readable")
let terminalNegotiation = "\u{1B}7\u{1B}[r\u{1B}8\u{1B}[?2004h\u{1B}[?2031h\u{1B}[?1004h\u{1B}[>0q\u{1B}[?u\u{1B}[c\u{1B}[>4m\u{1B}[<u"
expect(ClaudeUsageParser.parse(terminalNegotiation + completedRepaint, now: now, timeZone: zone) == windows,
       "Observed CLI terminal negotiation preserves the final screen")
expect(ClaudeTerminalScreen.render("\u{1B}[9999B") == nil,
       "Terminal cursor movement stays within the bounded capture")
expect(ClaudeTerminalScreen.render(panel + "\u{1B}[P") == nil,
       "Unsupported destructive terminal operations fail conservatively")
expect(ClaudeUsageParser.parse(refreshingPanel) == nil, "An uncleared refreshing screen remains stale")
let replacedFailure = "Showing last-known usage\n" + panel + "\u{1B}[2J\u{1B}[H" + panel
expect(ClaudeUsageParser.parse(replacedFailure, now: now, timeZone: zone) == windows,
       "Cleared terminal failures do not contaminate a subsequent complete screen")
expect(ClaudeUsageParser.parse(panel + "\u{1B}[2K") == nil,
       "Erasing the completion footer cannot turn a partial repaint into fresh data")
expect(ClaudeUsageParser.parse(panel + "\u{1B}[") == nil,
       "An incomplete terminal control sequence waits for the next chunk")
expect(ClaudeUsageParser.blockingError(in: panel + "\u{1B}[") == nil,
       "Split terminal sequences do not prematurely abort capture")
let terminalJSON = "\u{1B}7\u{1B}[r\u{1B}8{\"loggedIn\":false}\u{1B}(B\u{0F}\u{1B}7\u{1B}[r\u{1B}8"
expect(ClaudeUsageParser.clean(terminalJSON) == "{\"loggedIn\":false}", "Claude 2.1.217 terminal save/restore chatter")
let loggedOut = try JSONDecoder().decode(ClaudeAuthStatus.self,
    from: Data(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#.utf8))
expect(!loggedOut.supportsUsage, "Logged out auth status")
let apiKey = try JSONDecoder().decode(ClaudeAuthStatus.self,
    from: Data(#"{"loggedIn":true,"authMethod":"api_key"}"#.utf8))
let unidentified = try JSONDecoder().decode(ClaudeAuthStatus.self,
    from: Data(#"{"loggedIn":true,"authMethod":"oauth_token","email":" "}"#.utf8))
expect(unidentified.historyIdentity == nil, "Empty email must not identify history")
expect(!apiKey.supportsUsage, "API key account is not subscription quota")
let account = try JSONDecoder().decode(ClaudeAuthStatus.self,
    from: Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"sample@example.invalid","orgId":"one","subscriptionType":"max"}"#.utf8))
expect(account.supportsUsage, "Subscription auth status")
expect(account.historyIdentity == "sample@example.invalid|one", "Organization partitions history")

var schedule = ClaudeRefreshSchedule()
expect(schedule.mayRefresh(at: now, manual: true), "Initial refresh is allowed")
schedule.started(at: now)
expect(!schedule.mayRefresh(at: now.addingTimeInterval(59), manual: true), "Repeated clicks cannot flood CLI")
expect(schedule.mayRefresh(at: now.addingTimeInterval(60), manual: true), "Manual refresh after minimum interval")
expect(schedule.nextAutomaticAttempt(isPopoverVisible: true) == now.addingTimeInterval(300), "Foreground polls every five minutes")
expect(schedule.nextAutomaticAttempt(isPopoverVisible: false) == now.addingTimeInterval(600), "Background polls every ten minutes")
for delay in [300.0, 600, 1200, 1800, 1800] {
    schedule.failed(at: now, usageUnavailable: true)
    expect(schedule.retryAfter == now.addingTimeInterval(delay), "Cached/rate-limited requests back off with a cap")
    for manual in [true, false] {
        expect(!schedule.mayRefresh(at: now.addingTimeInterval(delay - 1), manual: manual), "Every refresh entry honors cooldown")
        expect(schedule.mayRefresh(at: now.addingTimeInterval(delay), manual: manual), "Retry resumes at cooldown expiry")
    }
    expect(schedule.nextAutomaticAttempt(isPopoverVisible: false) == schedule.retryAfter, "Background retry is not postponed by polling interval")
}
schedule.succeeded()
expect(schedule.retryAfter == nil, "Success clears cooldown")
schedule.failed(at: now, usageUnavailable: true)
expect(schedule.retryAfter == now.addingTimeInterval(300), "Success resets backoff count")
schedule.succeeded()
schedule.failed(at: now, usageUnavailable: false)
expect(schedule.retryAfter == now.addingTimeInterval(20), "Ordinary failures retain short retry")

let directory = FileManager.default.temporaryDirectory
let client = ClaudeCLIClient()
let text = try client.capture(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["capture-ok"],
    directory: directory, usage: false, timeout: 2)
expect(text.contains("capture-ok"), "PTY captures child output")
let directoryCheck = try ClaudeCLIClient().capture(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
    arguments: ["--check-working-directory", directory.path], directory: directory, usage: false, timeout: 2)
expect(directoryCheck.contains("directory-ok"), "Child PWD and actual working directory both match the probe directory")
let environmentCheck = try ClaudeCLIClient().capture(executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "test -z \"$CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\" && test \"$DISABLE_TELEMETRY\" = 1 && test \"$DISABLE_ERROR_REPORTING\" = 1 && test \"$DISABLE_AUTOUPDATER\" = 1 && printf environment-ok"],
    directory: directory, usage: false, timeout: 2)
expect(environmentCheck.contains("environment-ok"), "Quota requests stay enabled while diagnostics and auto-updates stay disabled")
func expectError(_ expected: ClaudeCLIError, executable: String, arguments: [String], usage: Bool, timeout: TimeInterval) {
    do {
        _ = try ClaudeCLIClient().capture(executable: URL(fileURLWithPath: executable), arguments: arguments,
            directory: directory, usage: usage, timeout: timeout)
        fatalError("Expected bounded failure: \(expected)")
    } catch let error as ClaudeCLIError {
        expect(error == expected, "Expected \(expected), received \(error)")
    } catch { fatalError("Unexpected capture error") }
}
expectError(.setupRequired, executable: "/bin/echo", arguments: ["Do you trust the files in this folder?"], usage: true, timeout: 2)
expectError(.usageCached, executable: "/bin/echo", arguments: [panel + "\nShowing last-known usage"], usage: true, timeout: 2)
expectError(.rateLimited, executable: "/bin/echo", arguments: ["Usage endpoint is rate limited"], usage: true, timeout: 2)
expectError(.outputTooLarge, executable: "/usr/bin/yes", arguments: [], usage: false, timeout: 2)
let descendantOutput = try ClaudeCLIClient().capture(executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"], directory: directory, usage: false, timeout: 2)
if let pid = Int32(descendantOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
    let deadline = Date().addingTimeInterval(1)
    while kill(pid, 0) == 0 && Date() < deadline { usleep(10_000) }
    expect(kill(pid, 0) != 0, "Descendant is cleaned up after CLI leader exits")
} else { fatalError("Missing descendant fixture PID") }
let started = Date()
expectError(.timedOut, executable: "/bin/sleep", arguments: ["5"], usage: false, timeout: 0.2)
expect(Date().timeIntervalSince(started) < 2, "Timeout and process cleanup are bounded")
let cancelled = ClaudeCLIClient()
cancelled.cancel()
do {
    _ = try cancelled.capture(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
        directory: directory, usage: false, timeout: 2)
    fatalError("Cancelled client must not launch")
} catch let error as ClaudeCLIError { expect(error == .cancelled, "Cancellation") }
print("Claude CLI checks passed: parser, cache/rate-limit classification, refresh cooldown, account identity, PTY, setup protection, timeout, output limit, cancellation.")

if CommandLine.arguments.contains("--live") {
    do {
        let live = try ClaudeCLIClient().fetch { status in
            print("Live CLI: loggedIn=\(status.loggedIn), subscription=\(status.supportsUsage)")
        }
        for window in live {
            print("\(window.id): \(window.remainingPercent)% remaining; reset=\(window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
        }
    } catch let error as ClaudeCLIError {
        print("Live CLI status: \(error.localizationKey)")
        exit(2)
    }
}

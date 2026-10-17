import Foundation
import Darwin

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

let directory = FileManager.default.temporaryDirectory
let client = ClaudeCLIClient()
let text = try client.capture(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["capture-ok"],
    directory: directory, usage: false, timeout: 2)
expect(text.contains("capture-ok"), "PTY captures child output")
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
print("Claude CLI checks passed: parser, account identity, PTY, setup protection, timeout, output limit, cancellation.")

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

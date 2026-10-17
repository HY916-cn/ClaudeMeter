import Foundation
import SQLite3

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
struct ClaudeRecoveryIntegration {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        func window(_ id: String, _ used: Int, _ duration: Int, _ reset: Date?) -> CodexUsageWindow {
            CodexUsageWindow(id: id, name: id, usedPercent: used,
                             windowDurationMins: duration, resetsAt: reset)
        }
        let session = window("claude-primary", 23, 300, time.addingTimeInterval(-30))
        let weekly = window("claude-secondary", 41, 10_080, time.addingTimeInterval(3_600))
        let sonnet = window("claude-sonnet-only-secondary", 8, 10_080, nil)
        var store: UsageHistoryStore? = try UsageHistoryStore(databaseURL: url)
        try await store!.recordQuotaSnapshots(
            [window("claude-retired-secondary", 5, 10_080, nil)],
            at: time.addingTimeInterval(-1_000), isStale: false, source: .refresh, accountKey: "account-a"
        )
        try await store!.recordQuotaSnapshots(
            [session, weekly, sonnet], at: time.addingTimeInterval(-600),
            isStale: false, source: .refresh, accountKey: "account-a"
        )
        let changedSession = window("claude-primary", 24, 300, session.resetsAt)
        try await store!.recordQuotaSnapshots(
            [changedSession, weekly, sonnet], at: time,
            isStale: false, source: .refresh, accountKey: "account-a"
        )
        let rejectedStale = try await store!.recordQuotaSnapshots(
            [window("claude-primary", 99, 300, nil)], at: time.addingTimeInterval(60),
            isStale: true, source: .refresh, accountKey: "account-a"
        )
        expect(!rejectedStale, "Stale observations cannot enter live history")
        try await store!.recordQuotaSnapshots(
            [window("developer-preview-weekly", 99, 10_080, nil),
             window("codex-primary", 99, 300, nil)],
            at: time.addingTimeInterval(60), isStale: false, source: .refresh, accountKey: "account-a"
        )
        try await store!.recordQuotaSnapshots(
            [window("claude-primary", 98, 300, nil)], at: time.addingTimeInterval(60),
            isStale: false, source: .notification, accountKey: "account-a"
        )
        try await store!.recordQuotaSnapshots(
            [window("claude-primary", 50, 300, nil)], at: time.addingTimeInterval(60),
            isStale: false, source: .refresh, accountKey: "account-b"
        )
        store = nil

        // Simulate a legacy/imported stale row that the current writer refuses to insert.
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { fatalError("Open test database") }
        defer { sqlite3_close(database) }
        let staleSQL = """
            INSERT INTO quota_samples (
                account_key, window_id, window_name, sampled_at, remaining_percent,
                window_duration_mins, resets_at, is_anchor, is_stale, starts_segment, source
            ) VALUES ('account-a', 'duration:300:claude', 'stale', 1700000120, 1,
                      300, NULL, 0, 1, 0, 'refresh');
            """
        expect(sqlite3_exec(database, staleSQL, nil, nil, nil) == SQLITE_OK, "Seed historical stale row")

        let reopened = try UsageHistoryStore(databaseURL: url)
        let before = try await reopened.quotaSamples(since: .distantPast, accountKey: "account-a")
        guard let recovered = try await reopened.latestClaudeUsage(accountKey: "account-a") else {
            fatalError("Successful quota survives a restart")
        }
        expect(recovered.windows.count == 3, "Recover active Claude buckets only")
        expect(recovered.windows.map(\.id) == ["claude-primary", "claude-secondary", "duration:10080:claude-sonnet-only"],
               "Standard quota IDs retain UI selection; other history IDs remain stable")
        expect(recovered.windows.map(\.remainingPercent) == [76, 59, 92], "Preserve actual recorded percentages")
        expect(recovered.sampledAt == time.addingTimeInterval(-600), "Keep conservative age across deduplicated buckets")
        expect(recovered.windows[0].resetsAt == session.resetsAt, "Expired resets remain the recorded reset")
        expect(recovered.windows[0].remainingTimePercent(at: time) == nil, "Expired reset does not fabricate time progress")
        expect(recovered.windows[0].remainingPercent == 76, "Expired reset does not fabricate replenished quota")
        expect(recovered.windows[2].resetsAt == nil, "Missing reset stays unknown")
        let after = try await reopened.quotaSamples(since: .distantPast, accountKey: "account-a")
        expect(before == after, "Recovery does not insert or alter history")
        let other = try await reopened.latestClaudeUsage(accountKey: "account-b")
        expect(other?.windows.first?.remainingPercent == 50, "Account history stays isolated")
        let missing = try await reopened.latestClaudeUsage(accountKey: "missing")
        let unidentified = try await reopened.latestClaudeUsage(accountKey: "")
        expect(missing == nil && unidentified == nil, "Missing identities cannot recover another account")

        func sample(_ percentage: Int, duration: Int?) -> QuotaHistorySample {
            QuotaHistorySample(id: 1, windowID: "duration:300:claude", windowName: "session", sampledAt: time,
                remainingPercent: percentage, windowDurationMins: duration, resetsAt: nil,
                startsSegment: false, isAnchor: false, isStale: false, source: .refresh)
        }
        expect(ClaudeUsageSnapshot.fromHistorySamples([sample(101, duration: 300)]) == nil,
               "Invalid percentages cannot become a recovered quota")
        expect(ClaudeUsageSnapshot.fromHistorySamples([sample(50, duration: 0), sample(50, duration: 10_080)]) == nil,
               "Invalid or mismatched duration cannot become a recovered quota")
        print("Claude recovery integration passed: restart, original age, reset semantics, read-only recovery, and account isolation")
    }
}

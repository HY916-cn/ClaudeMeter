import Foundation
import Combine
import AppKit

final class AppSettings {
    enum Destination { case notifications }
    var notificationsEnabled = true
    var settingsDestination: Destination = .notifications
    var notificationThreshold = 20
    let historyIdentitySalt = "claude-service-integration-fixture-salt"
    var historyRetention: HistoryRetention = .forever
    func clearSettingsError() {}
    func showSettingsError(_ message: String, destination: Destination) {}
}

final class NotificationManager {
    private(set) var evaluations = 0
    func requestAuthorization(completion: (Bool, String?) -> Void) { completion(true, nil) }
    func evaluate(windows: [CodexUsageWindow], threshold: Int) { evaluations += 1 }
    func resetEvaluationState() {}
}

final class PushNotificationService {
    private(set) var evaluations = 0
    init(settings: AppSettings) {}
    func evaluate(windows: [CodexUsageWindow]) { evaluations += 1 }
    func resetEvaluationState() {}
    func sendTestBark(completion: ((Bool, String?) -> Void)?) {}
    func sendTestGotify(completion: ((Bool, String?) -> Void)?) {}
}

enum L10n {
    static func string(_ key: String) -> String { key }
    static func format(_ key: String, _ arguments: CVarArg...) -> String { "\(key): \(arguments)" }
    static func formattedTime(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

/// This target excludes the real CLI client, so every refresh stays in the fixture.
nonisolated final class ClaudeCLIClient: @unchecked Sendable {
    struct Fixture: Sendable {
        let accounts: [ClaudeAuthStatus]
        let result: Result<[CodexUsageWindow], ClaudeCLIError>
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var next: Fixture?
    nonisolated(unsafe) private static var calls = 0
    private let fixture: Fixture

    static func configure(_ fixture: Fixture) {
        lock.lock()
        defer { lock.unlock() }
        next = fixture
        calls = 0
    }

    static var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    init() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let fixture = Self.next else { fatalError("Missing CLI fixture") }
        self.fixture = fixture
    }

    func fetch(onAccount: (ClaudeAuthStatus) -> Void) throws -> [CodexUsageWindow] {
        Self.lock.lock()
        Self.calls += 1
        Self.lock.unlock()
        for account in fixture.accounts { onAccount(account) }
        return try fixture.result.get()
    }

    func cancel() {}
}

@main
struct Integration {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    static func until(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(condition(), message)
    }

    static func account(_ email: String) throws -> ClaudeAuthStatus {
        let data = try JSONSerialization.data(withJSONObject: [
            "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
            "email": email, "orgId": "fixture-org", "subscriptionType": "pro"
        ])
        return try JSONDecoder().decode(ClaudeAuthStatus.self, from: data)
    }

    static func windows(used: Int, sampledAt: Date) -> [CodexUsageWindow] {
        [CodexUsageWindow(id: "claude-primary", name: "duration.five_hours", usedPercent: used,
            windowDurationMins: 300, resetsAt: sampledAt.addingTimeInterval(18_000)),
         CodexUsageWindow(id: "claude-secondary", name: "duration.weekly", usedPercent: used + 10,
            windowDurationMins: 10_080, resetsAt: sampledAt.addingTimeInterval(604_800))]
    }

    static func main() {
        // The production service uses Foundation timers on the main run loop.
        // Keep that loop running while the asynchronous checks await real callbacks.
        Task {
            do {
                try await runChecks()
                exit(EXIT_SUCCESS)
            } catch {
                fatalError("Service integration failed: \(error)")
            }
        }
        CFRunLoopRun()
    }

    static func runChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let settings = AppSettings()
        let accountA = try account("restart-a@example.invalid")
        let accountB = try account("restart-b@example.invalid")
        let keyA = HistoryAccountIdentity.make(accountType: "claude", email: accountA.historyIdentity,
            salt: settings.historyIdentitySalt).key
        let keyB = HistoryAccountIdentity.make(accountType: "claude", email: accountB.historyIdentity,
            salt: settings.historyIdentitySalt).key
        let sampledAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 600)
        let savedWindows = windows(used: 23, sampledAt: sampledAt)
        let store = try UsageHistoryStore(databaseURL: databaseURL)
        try await store.prepareDatabase()
        _ = try await store.recordQuotaSnapshots(savedWindows, at: sampledAt, isStale: false,
            source: .refresh, accountKey: keyA)
        let seededCount = try await store.quotaSamples(since: .distantPast, accountKey: keyA).count

        // A new model/service represents a fresh app process over an existing database.
        do {
            ClaudeCLIClient.configure(.init(accounts: [accountA], result: .failure(.usageCached)))
            let history = UsageHistoryModel(databaseURL: databaseURL)
            let notifications = NotificationManager()
            let push = PushNotificationService(settings: settings)
            let service = CodexUsageService(settings: settings, history: history,
                notificationManager: notifications, pushNotificationService: push)
            try await until("Restart restores saved quota after cached CLI failure") {
                service.windows.count == 2 && service.errorMessage != nil && !service.isRefreshInFlight
            }
            check(service.windows == savedWindows, "Restored quota keeps IDs, percentages, durations and resets")
            check(service.lastUpdated == sampledAt, "Restore keeps the original successful sample timestamp")
            check(service.isStale && !service.isLoading, "Restored quota remains visibly stale without a loading state")
            check(service.errorMessage?.contains("error.claude_usage_cached") == true,
                  "Restore preserves the current cache-fallback error")
            service.refresh()
            service.refreshIfNeeded(maxAge: 0)
            try await settle()
            check(ClaudeCLIClient.fetchCount == 1, "Restart recovery and refresh clicks respect the failure cooldown")
            // Wait beyond the normal foreground age so this exercises the failure
            // cooldown rather than the wake handler's fresh-sample guard.
            try await Task.sleep(nanoseconds: UInt64((ClaudeRefreshSchedule.foregroundInterval + 0.2) * 1_000_000_000))
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await settle()
            check(ClaudeCLIClient.fetchCount == 1 && service.isStale,
                  "Wake preserves the failure cooldown after the normal refresh age")
            check(notifications.evaluations == 0 && push.evaluations == 0, "Restoration sends no quota notifications")
            let count = try await store.quotaSamples(since: .distantPast, accountKey: keyA).count
            check(count == seededCount, "Restoration adds no fresh history rows")
        }

        do {
            let freshWindows = windows(used: 37, sampledAt: sampledAt)
            ClaudeCLIClient.configure(.init(accounts: [accountA], result: .success(freshWindows)))
            let history = UsageHistoryModel(databaseURL: databaseURL)
            let notifications = NotificationManager()
            let push = PushNotificationService(settings: settings)
            let service = CodexUsageService(settings: settings, history: history,
                notificationManager: notifications, pushNotificationService: push)
            try await until("Fresh CLI response completes during startup history restoration") {
                service.lastUpdated != nil && !service.isStale && !service.isRefreshInFlight
            }
            try await settle()
            check(service.windows == freshWindows && service.lastUpdated! > sampledAt,
                  "A delayed restoration cannot overwrite a fresh CLI response")
            check(!service.isStale && service.errorMessage == nil, "Fresh response clears stale state and errors")
            check(notifications.evaluations == 1 && push.evaluations == 1,
                  "Only the fresh response evaluates quota notifications")
            service.setPopoverVisible(true)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await settle()
            check(ClaudeCLIClient.fetchCount == 1, "Immediate wake does not duplicate a fresh quota request")
            let firstUpdated = service.lastUpdated!
            try await until("Visible popover automatically refreshes without a manual request",
                            timeout: ClaudeRefreshSchedule.foregroundInterval + 5) {
                ClaudeCLIClient.fetchCount == 2 && !service.isRefreshInFlight
                    && service.lastUpdated! > firstUpdated
            }
            check(service.windows == freshWindows && !service.isStale,
                  "Automatic refresh preserves valid quota and advances its observation time")
            service.setPopoverVisible(false)
            let automaticUpdated = service.lastUpdated!
            try await Task.sleep(nanoseconds: UInt64((ClaudeRefreshSchedule.foregroundInterval + 0.2) * 1_000_000_000))
            check(ClaudeCLIClient.fetchCount == 2, "Hidden popover uses the longer background interval")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await until("Wake refreshes an aged sample before the background timer is due", timeout: 5) {
                ClaudeCLIClient.fetchCount == 3 && !service.isRefreshInFlight
                    && service.lastUpdated! > automaticUpdated
            }
        }

        do {
            ClaudeCLIClient.configure(.init(accounts: [accountA, accountB], result: .failure(.usageCached)))
            let history = UsageHistoryModel(databaseURL: databaseURL)
            let notifications = NotificationManager()
            let push = PushNotificationService(settings: settings)
            let service = CodexUsageService(settings: settings, history: history,
                notificationManager: notifications, pushNotificationService: push)
            try await until("Account switch completes while restoration is pending") {
                service.historyAccountKey == keyB && service.errorMessage != nil && !service.isRefreshInFlight
            }
            try await settle()
            check(service.windows.isEmpty && service.lastUpdated == nil,
                  "An account without history never receives another account's saved quota")
            check(!service.isLoading && notifications.evaluations == 0 && push.evaluations == 0,
                  "Failed refresh after account switch completes without notifications")
            let count = try await store.quotaSamples(since: .distantPast, accountKey: keyB).count
            check(count == 0, "Account switching does not copy history into the new account")
        }
        print("Claude service integration checks passed: real SQLite restart recovery, stale state, timestamps, cooldown, automatic timer, wake handling, fresh response, account isolation.")
    }
}

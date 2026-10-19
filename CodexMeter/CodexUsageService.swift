import AppKit
import Combine
import Foundation

/// Exposes Claude CLI subscription quota while the official CLI owns authentication.
final class CodexUsageService: ObservableObject {
    @Published private(set) var windows: [CodexUsageWindow] = []
    @Published private(set) var planType: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshInFlight = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var isTokenUsageUnavailable = true
    @Published private(set) var tokenUsageErrorMessage: String?
    @Published private(set) var rateLimitResetCredits: CodexRateLimitResetCreditsSummary?

    private let settings: AppSettings
    private let notificationManager: NotificationManager
    let pushNotificationService: PushNotificationService
    private let history: UsageHistoryModel
    private var client: ClaudeCLIClient?
    private var refreshTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isPopoverVisible = false
    private var lastHistorySnapshot: [CodexUsageWindow]?
    private var lastHistoryAccountKey: String?
    private var lastHistoryRecordAt: Date?
    private var refreshSchedule = ClaudeRefreshSchedule()
    private(set) var historyAccountKey: String?

    init(settings: AppSettings, history: UsageHistoryModel,
         notificationManager: NotificationManager = NotificationManager(),
         pushNotificationService: PushNotificationService? = nil) {
        self.settings = settings
        self.history = history
        self.notificationManager = notificationManager
        self.pushNotificationService = pushNotificationService ?? PushNotificationService(settings: settings)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.client?.cancel() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshIfNeeded()
            self.installRefreshTimer()
        }
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    var mostConstrainedRemainingPercent: Int? { mostConstrainedWindow?.remainingPercent }
    var mostConstrainedWindow: CodexUsageWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }
    var menuBarTitle: String {
        mostConstrainedRemainingPercent.map { "\($0)%" } ?? (isLoading ? "…" : "--")
    }
    var accountDescription: String {
        guard let planType else { return L10n.string("account.checking") }
        return L10n.format("account.chatgpt_format", planType.capitalized)
    }

    func start() { refresh() }

    func refresh() {
        performRefresh(manual: true)
    }

    private func performRefresh(manual: Bool) {
        let now = Date()
        guard !isRefreshInFlight, refreshSchedule.mayRefresh(at: now, manual: manual) else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        isRefreshInFlight = true
        isLoading = windows.isEmpty
        errorMessage = nil
        refreshSchedule.started(at: now)
        let client = ClaudeCLIClient()
        self.client = client
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try client.fetch { account in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.client === client else { return }
                    self.applyAccount(account)
                }
            } }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.client === client else { return }
                self.client = nil
                switch result {
                case .success(let parsed): self.applyWindows(parsed)
                case .failure(let error):
                    self.markFailure(error as? ClaudeCLIError ?? .communication)
                }
            }
        }
    }

    func refreshIfNeeded(maxAge: TimeInterval = ClaudeRefreshSchedule.foregroundInterval) {
        guard refreshSchedule.lastAttempt.map({ Date().timeIntervalSince($0) >= maxAge }) ?? true else { return }
        performRefresh(manual: false)
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        installRefreshTimer()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.notificationsEnabled = false
            if settings.settingsDestination == .notifications {
                settings.clearSettingsError()
            }
            return
        }

        notificationManager.requestAuthorization { [weak self] granted, error in
            guard let self else { return }
            self.settings.notificationsEnabled = granted
            if granted {
                self.settings.clearSettingsError()
                if self.historyAccountKey != nil, !self.isStale {
                    self.notificationManager.evaluate(
                        windows: self.windows,
                        threshold: self.settings.notificationThreshold
                    )
                }
            } else {
                let message = error ?? L10n.string("settings.notification_denied")
                self.settings.showSettingsError(message, destination: .notifications)
            }
        }
    }

    func sendTestBarkPush(completion: ((Bool, String?) -> Void)? = nil) {
        pushNotificationService.sendTestBark(completion: completion)
    }

    func sendTestGotifyPush(completion: ((Bool, String?) -> Void)? = nil) {
        pushNotificationService.sendTestGotify(completion: completion)
    }

    private func installRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard !isRefreshInFlight,
              let nextAttempt = refreshSchedule.nextAutomaticAttempt(isPopoverVisible: isPopoverVisible) else { return }
        let timer = Timer(timeInterval: max(0.1, nextAttempt.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.performRefresh(manual: false)
            }
        }
        timer.tolerance = isPopoverVisible ? 1 : 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func applyAccount(_ account: ClaudeAuthStatus) {
        let identity = account.loggedIn && account.historyIdentity != nil ? HistoryAccountIdentity.make(
            accountType: "claude", email: account.historyIdentity, salt: settings.historyIdentitySalt
        ) : nil
        if identity == nil || historyAccountKey != identity?.key {
            windows = []
            lastUpdated = nil
            isStale = false
            tokenUsage = nil
            lastHistorySnapshot = nil
            lastHistoryAccountKey = nil
            lastHistoryRecordAt = nil
            historyAccountKey = identity?.key
            notificationManager.resetEvaluationState()
            pushNotificationService.resetEvaluationState()
            if let identity {
                history.activateAccount(identity.key, resetExisting: false, claimLegacyHistory: false)
                restoreLastKnownUsage(accountKey: identity.key)
            } else {
                history.deactivateAccount()
            }
        }
        planType = account.loggedIn ? (account.subscriptionType ?? account.authMethod ?? "Claude") : nil
    }

    private func restoreLastKnownUsage(accountKey: String) {
        Task { [weak self] in
            guard let self,
                  let snapshot = await self.history.latestClaudeUsage(accountKey: accountKey),
                  self.historyAccountKey == accountKey,
                  self.windows.isEmpty, self.lastUpdated == nil else { return }
            // A delayed disk read must never replace fresh CLI data or another account.
            self.windows = self.localizedWindows(snapshot.windows)
            self.lastUpdated = snapshot.sampledAt
            self.isStale = true
            self.isLoading = false
        }
    }

    private func localizedWindows(_ parsed: [CodexUsageWindow]) -> [CodexUsageWindow] {
        parsed.map { window in
            let name: String
            if window.id == "claude-primary" { name = L10n.string("duration.five_hours") }
            else if window.id == "claude-secondary" { name = L10n.string("duration.weekly") }
            else { name = window.name }
            return CodexUsageWindow(id: window.id, name: name, usedPercent: window.usedPercent,
                windowDurationMins: window.windowDurationMins, resetsAt: window.resetsAt)
        }
    }

    private func applyWindows(_ parsed: [CodexUsageWindow]) {
        NSLog("ClaudeMeter quota refresh succeeded: %d windows", parsed.count)
        let parsed = localizedWindows(parsed)
        let updatedAt = Date()
        windows = parsed
        isLoading = false
        isRefreshInFlight = false
        isStale = false
        lastUpdated = updatedAt
        errorMessage = nil
        refreshSchedule.succeeded()
        installRefreshTimer()
        if let historyAccountKey,
           shouldRecordQuotaHistory(parsed, accountKey: historyAccountKey, at: updatedAt) {
            lastHistoryAccountKey = historyAccountKey
            lastHistorySnapshot = parsed
            lastHistoryRecordAt = updatedAt
            history.recordQuota(windows: parsed, at: updatedAt, isStale: false, source: .refresh,
                retention: settings.historyRetention, accountKey: historyAccountKey)
        }
        if historyAccountKey != nil, settings.notificationsEnabled {
            notificationManager.evaluate(windows: parsed, threshold: settings.notificationThreshold)
        }
        if historyAccountKey != nil {
            pushNotificationService.evaluate(windows: parsed)
        }
    }

    private func shouldRecordQuotaHistory(
        _ current: [CodexUsageWindow],
        accountKey: String,
        at date: Date
    ) -> Bool {
        guard lastHistoryAccountKey == accountKey,
              let previous = lastHistorySnapshot,
              let lastHistoryRecordAt else { return true }
        if date.timeIntervalSince(lastHistoryRecordAt) >= 15 * 60 { return true }
        guard previous.count == current.count else { return true }
        let previousByID = Dictionary(previous.map { ($0.historyID, $0) },
                                      uniquingKeysWith: { first, _ in first })
        return current.contains { window in
            guard let prior = previousByID[window.historyID] else { return true }
            return prior.remainingPercent != window.remainingPercent
                || prior.windowDurationMins != window.windowDurationMins
                || prior.name != window.name
                || QuotaCycleDetection.resetMeaningfullyChanged(
                    previousRemaining: prior.remainingPercent,
                    previousReset: prior.resetsAt,
                    currentRemaining: window.remainingPercent,
                    currentReset: window.resetsAt
                )
        }
    }

    private func markFailure(_ error: ClaudeCLIError) {
        NSLog("ClaudeMeter quota refresh failed: %@", String(describing: error))
        refreshSchedule.failed(at: Date(), usageUnavailable: error == .usageCached || error == .rateLimited)
        isLoading = false
        isRefreshInFlight = false
        isStale = !windows.isEmpty
        let message = L10n.string(error.localizationKey)
        errorMessage = refreshSchedule.retryAfter.map {
            message + " " + L10n.format("error.claude_retry_at", L10n.formattedTime($0))
        } ?? message
        installRefreshTimer()
    }

    deinit {
        refreshTimer?.invalidate()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        client?.cancel()
    }
}

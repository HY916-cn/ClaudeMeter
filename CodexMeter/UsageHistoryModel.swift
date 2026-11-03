import Combine
import Foundation

/// Bridges the actor-backed history store to SwiftUI without blocking the menu bar.
@MainActor
final class UsageHistoryModel: ObservableObject {
    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var storageSize: Int64 = 0
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var dataRevision = 0
    @Published private(set) var activeAccountKey: String?
    @Published private(set) var isRestoring = false
    @Published private(set) var needsRestart = false

    let databaseURL: URL
    private let store: UsageHistoryStore?
    private var accountPreparationTask: Task<Void, Never>?

    init(databaseURL: URL = UsageHistoryStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
        do {
            store = try UsageHistoryStore(databaseURL: databaseURL)
        } catch {
            store = nil
            errorMessage = error.localizedDescription
        }

        Task { await prepare() }
    }

    /// Read an account-scoped fallback without creating a fresh history sample.
    func latestClaudeUsage(accountKey: String) async -> ClaudeUsageSnapshot? {
        guard let store, !isRestoring, !needsRestart, activeAccountKey == accountKey else { return nil }
        await accountPreparationTask?.value
        guard !isRestoring, !needsRestart, activeAccountKey == accountKey else { return nil }
        return try? await store.latestClaudeUsage(accountKey: accountKey)
    }

    func recordQuota(
        windows: [CodexUsageWindow],
        at date: Date,
        isStale: Bool,
        source: QuotaSampleSource,
        retention: HistoryRetention,
        accountKey: String
    ) {
        guard let store, !isRestoring, !needsRestart else { return }
        let accountPreparationTask = self.accountPreparationTask
        Task {
            await accountPreparationTask?.value
            do {
                let changed = try await store.recordQuotaSnapshots(
                    windows,
                    at: date,
                    isStale: isStale,
                    source: source,
                    accountKey: accountKey
                )
                guard changed else { return }
                try await store.applyRetention(retention, now: date)
                if activeAccountKey == accountKey {
                    dataRevision += 1
                    await refreshMetadata()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func recordTokenUsage(
        _ snapshot: TokenUsageSnapshot,
        retention: HistoryRetention,
        accountKey: String
    ) {
        guard let store, !isRestoring, !needsRestart else { return }
        if activeAccountKey == accountKey {
            tokenUsage = snapshot
        }
        let accountPreparationTask = self.accountPreparationTask
        Task {
            await accountPreparationTask?.value
            do {
                try await store.recordTokenUsage(snapshot, accountKey: accountKey)
                try await store.applyRetention(retention, now: snapshot.fetchedAt)
                if activeAccountKey == accountKey {
                    dataRevision += 1
                    await refreshMetadata()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func load() async {
        guard let store else { return }
        guard let accountKey = activeAccountKey else {
            tokenUsage = nil
            storageSize = await store.storageSize()
            return
        }
        isLoading = true
        defer {
            if activeAccountKey == accountKey {
                isLoading = false
            }
        }

        do {
            let loadedTokenUsage = try await store.tokenUsage(accountKey: accountKey)
            let loadedStorageSize = await store.storageSize()
            guard activeAccountKey == accountKey else { return }
            tokenUsage = loadedTokenUsage
            storageSize = loadedStorageSize
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateAccount(
        _ accountKey: String,
        resetExisting: Bool,
        claimLegacyHistory: Bool
    ) {
        guard !isRestoring, !needsRestart else { return }
        activeAccountKey = accountKey
        tokenUsage = nil
        dataRevision += 1

        guard let store else { return }
        let task = Task {
            do {
                if resetExisting {
                    try await store.clearAccount(accountKey)
                }
                if claimLegacyHistory {
                    try await store.claimLegacyHistory(for: accountKey)
                }
                guard activeAccountKey == accountKey else { return }
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        accountPreparationTask = task
    }

    func deactivateAccount() {
        activeAccountKey = nil
        tokenUsage = nil
        dataRevision += 1
        accountPreparationTask = nil
    }

    func applyRetention(_ retention: HistoryRetention) async {
        guard let store else { return }
        do {
            try await store.applyRetention(retention)
            dataRevision += 1
            await refreshMetadata()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() async {
        guard let store else { return }
        do {
            try await store.clearAll()
            tokenUsage = nil
            dataRevision += 1
            await refreshMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateDeveloperPreviewData() async {
        guard let store, let accountKey = activeAccountKey else { return }
        do {
            try await store.replaceDeveloperPreviewData(
                windowName: L10n.string("developer.history_preview_window"),
                accountKey: accountKey
            )
            dataRevision += 1
            await refreshMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearDeveloperPreviewData() async {
        guard let store, let accountKey = activeAccountKey else { return }
        do {
            try await store.clearDeveloperPreviewData(accountKey: accountKey)
            dataRevision += 1
            await refreshMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportCSV() async throws -> Data {
        guard let store else {
            throw UsageHistoryStoreError.openDatabase(
                errorMessage ?? "History storage is unavailable."
            )
        }
        guard let accountKey = activeAccountKey else {
            throw UsageHistoryStoreError.openDatabase("No active account history is available.")
        }
        return try await store.exportCSV(accountKey: accountKey)
    }

    func exportBackup(salt: String, appVersion: String) async throws -> Data {
        guard let store, !isRestoring, !needsRestart else { throw HistoryBackupError.storageFailure }
        return try await store.exportBackup(identitySalt: salt, appVersion: appVersion)
    }

    func restoreBackup(from url: URL, salt: String, appVersion: String) async throws -> URL {
        guard let store, !isRestoring, !needsRestart else { throw HistoryBackupError.storageFailure }
        isRestoring = true
        defer { isRestoring = false }
        await accountPreparationTask?.value
        let recovery = try await store.restoreBackup(
            from: url, identitySalt: salt, appVersion: appVersion,
            persistSalt: { salt in
                UserDefaults.standard.set(salt, forKey: "history.identitySalt")
                guard UserDefaults.standard.synchronize() else { throw HistoryBackupError.storageFailure }
            }
        )
        needsRestart = true
        deactivateAccount()
        return recovery
    }

    func refreshMetadata() async {
        guard let store else { return }
        do {
            guard let accountKey = activeAccountKey else {
                storageSize = await store.storageSize()
                return
            }
            let loadedTokenUsage = try await store.tokenUsage(accountKey: accountKey)
            let loadedStorageSize = await store.storageSize()
            guard activeAccountKey == accountKey else { return }
            tokenUsage = loadedTokenUsage
            storageSize = loadedStorageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepare() async {
        guard let store else { return }
        do {
            try await store.prepareDatabase()
            isReady = true
            if activeAccountKey == nil {
                storageSize = await store.storageSize()
            } else {
                await load()
            }
        } catch {
            // History failures remain isolated; live quota display continues normally.
            errorMessage = error.localizedDescription
        }
    }
}

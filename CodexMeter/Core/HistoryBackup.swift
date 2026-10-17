import CryptoKit
import Foundation
import SQLite3

enum HistoryBackupError: Error, Equatable {
    case invalidArchive, unsupportedVersion, invalidDatabase, storageFailure
}

/// A single binary property-list container avoids archive path traversal and external tools.
nonisolated struct HistoryBackup: Codable, Sendable {
    static func journalURL(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("InterruptedRestore.claudemeterbackup")
    }

    /// Restore the previous database and salt if termination interrupted their coordinated update.
    static func recoverInterruptedRestore(
        databaseURL: URL, persistSalt: (String) throws -> Void
    ) throws {
        let journal = journalURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let archive = try read(from: journal)
        let temporary = databaseURL.deletingLastPathComponent().appendingPathComponent("recovery-\(UUID().uuidString).sqlite")
        try archive.database.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var source: OpaquePointer?
        var destination: OpaquePointer?
        defer { sqlite3_close(source); sqlite3_close(destination) }
        guard sqlite3_open_v2(temporary.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open(databaseURL.path, &destination) == SQLITE_OK else {
            throw HistoryBackupError.storageFailure
        }
        let info = try inspect(source)
        guard info.counts == archive.manifest.rowCounts else { throw HistoryBackupError.invalidDatabase }
        try copyDatabase(from: source, to: destination)
        try persistSalt(archive.manifest.identitySalt)
        try FileManager.default.removeItem(at: journal)
    }

    nonisolated struct Manifest: Codable, Sendable {
        let formatVersion: Int
        let schemaVersion: Int
        let createdAt: Date
        let appVersion: String
        let identitySalt: String
        let checksum: String
        let rowCounts: [String: Int64]
    }
    let manifest: Manifest
    let database: Data

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        // Never create an export or rollback journal that our reader cannot reopen.
        guard data.count <= 512 * 1024 * 1024 else { throw HistoryBackupError.invalidArchive }
        return data
    }

    static func read(from url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw HistoryBackupError.invalidArchive }
        let archive: Self
        do { archive = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { throw HistoryBackupError.invalidArchive }
        guard archive.manifest.formatVersion == 1,
              (3...UsageHistoryStore.schemaVersion).contains(archive.manifest.schemaVersion)
        else { throw HistoryBackupError.unsupportedVersion }
        guard !archive.manifest.identitySalt.isEmpty, archive.manifest.identitySalt.count <= 256,
              archive.database.starts(with: Data("SQLite format 3\0".utf8)),
              checksum(archive.database) == archive.manifest.checksum
        else { throw HistoryBackupError.invalidArchive }
        return archive
    }

    /// SQLite's backup transaction includes committed WAL pages and rolls back incomplete copies.
    static func copyDatabase(from source: OpaquePointer?, to destination: OpaquePointer?) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw HistoryBackupError.storageFailure
        }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw HistoryBackupError.storageFailure }
    }

    static func inspect(_ database: OpaquePointer?) throws -> (version: Int, counts: [String: Int64]) {
        func scalar(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw HistoryBackupError.invalidDatabase
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                throw HistoryBackupError.invalidDatabase
            }
            return String(cString: value)
        }
        guard try scalar("PRAGMA integrity_check") == "ok" else { throw HistoryBackupError.invalidDatabase }
        let version = Int(try scalar("PRAGMA user_version")) ?? -1
        guard (3...UsageHistoryStore.schemaVersion).contains(version) else {
            throw HistoryBackupError.unsupportedVersion
        }
        // Reject unexpected schema objects, including triggers and virtual tables.
        guard try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND (type NOT IN ('table','index') OR (type='table' AND name NOT IN ('quota_samples','token_daily','token_summary')) OR upper(sql) LIKE '%VIRTUAL%')") == "0" else {
            throw HistoryBackupError.invalidDatabase
        }
        var counts: [String: Int64] = [:]
        for table in ["quota_samples", "token_daily", "token_summary"] {
            counts[table] = Int64(try scalar("SELECT count(*) FROM \(table)"))
        }
        return (version, counts)
    }
}

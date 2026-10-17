import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A grouped settings section; the containing settings window owns native file panels.
struct HistoryBackupView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @State private var busy = false
    @State private var pendingURL: URL?
    @State private var message: String?
    @State private var recoveryURL: URL?

    private var backupType: UTType { UTType(filenameExtension: "claudemeterbackup") ?? .data }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var body: some View {
        Section(L10n.string("backup.title")) {
            Text(L10n.string("backup.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                Button(L10n.string("backup.export"), action: export)
                Button(L10n.string("backup.restore"), action: chooseRestore)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy || history.needsRestart || !history.isReady)
            if let message { Text(message).textSelection(.enabled) }
            if let recoveryURL {
                Button(L10n.string("backup.show_recovery")) {
                    NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                }
            }
            if history.needsRestart {
                Text(L10n.string("backup.restart")).foregroundStyle(.secondary)
                Button(L10n.string("backup.quit")) { NSApplication.shared.terminate(nil) }
            }
        }
        .confirmationDialog(
            L10n.string("backup.confirm_title"),
            isPresented: Binding(get: { pendingURL != nil }, set: { if !$0 { pendingURL = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.string("backup.restore"), role: .destructive) {
                guard let url = pendingURL else { return }
                pendingURL = nil
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        recoveryURL = try await history.restoreBackup(
                            from: url, salt: settings.historyIdentitySalt, appVersion: version
                        )
                        message = L10n.string("backup.restored")
                    } catch { message = L10n.string("backup.failed") }
                }
            }
            Button(L10n.string("backup.cancel"), role: .cancel) { pendingURL = nil }
        } message: {
            Text(L10n.string("backup.confirm_message"))
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [backupType]
        panel.nameFieldStringValue = "ClaudeMeter-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).claudemeterbackup"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            busy = true
            Task {
                defer { busy = false }
                do {
                    let data = try await history.exportBackup(salt: settings.historyIdentitySalt, appVersion: version)
                    try data.write(to: url, options: .atomic)
                    message = L10n.string("backup.exported")
                } catch { message = L10n.string("backup.failed") }
            }
        }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [backupType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK { pendingURL = panel.url }
        }
    }
}

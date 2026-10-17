import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shares existing settings objects so reorganizing controls never migrates preferences.
struct AppSettingsView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String? = "settings.category.general"
    @State private var showsClearConfirmation = false
    @State private var actionError: String?

    private let categories = [
        ("settings.category.general", "gearshape"),
        ("settings.category.menu", "menubar.rectangle"),
        ("settings.category.notifications", "bell"),
        ("settings.category.history", "externaldrive"),
        ("developer.title", "hammer"),
        ("about.title", "info.circle")
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(categories, id: \.0) { key, symbol in
                    Label(L10n.string(key), systemImage: symbol).tag(key)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection {
                case "settings.category.menu":
                    PopoverCustomizationView(service: service, settings: settings)
                case "settings.category.history":
                    historySettings
                case "settings.category.notifications":
                    NotificationsSettingsView(service: service, settings: settings,
                                              push: service.pushNotificationService)
                case "developer.title":
                    DeveloperOptionsView(settings: settings, history: history,
                                         updateChecker: updateChecker, embedded: true)
                case "about.title":
                    AboutView(settings: settings, history: history,
                              updateChecker: updateChecker, embedded: true)
                default:
                    generalSettings
                }
            }
            .navigationTitle(L10n.string(selection ?? "settings.category.general"))
        }
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .alert(L10n.string("settings.error_title"), isPresented: Binding(
            get: { settings.settingsError != nil || actionError != nil },
            set: { if !$0 { settings.clearSettingsError(); actionError = nil } }
        )) {
            Button(L10n.string("action.ok")) { settings.clearSettingsError(); actionError = nil }
            if settings.settingsDestination != nil {
                Button(L10n.string("action.open_system_settings")) {
                    settings.openRelevantSystemSettings()
                    settings.clearSettingsError()
                }
            }
        } message: {
            Text(settings.settingsError ?? actionError ?? "")
        }
        .alert(L10n.string("history.clear.title"), isPresented: $showsClearConfirmation) {
            Button(L10n.string("action.cancel"), role: .cancel) { }
            Button(L10n.string("history.clear.confirm"), role: .destructive) {
                Task { await history.clearAll(); actionError = history.errorMessage }
            }
        } message: { Text(L10n.string("history.clear.message")) }
    }

    private var generalSettings: some View {
        Form {
            Section {
                Picker(L10n.string("settings.language"), selection: Binding(
                    get: { settings.language },
                    set: { settings.language = $0; service.refresh() }
                )) {
                    ForEach(AppLanguage.allCases) { Text($0.localizedName).tag($0) }
                }
                Picker(L10n.string("settings.appearance"), selection: $settings.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { Text($0.localizedName).tag($0) }
                }
                Toggle(L10n.string("settings.launch_at_login"), isOn: Binding(
                    get: { settings.launchAtLoginEnabled }, set: { settings.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }

    private var historySettings: some View {
        Form {
            Section(L10n.string("history.storage.title")) {
                Picker(L10n.string("history.retention"), selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.localizedName).tag($0) }
                }
                .onChange(of: settings.historyRetention) { value in
                    Task { await history.applyRetention(value); actionError = history.errorMessage }
                }
                LabeledContent(L10n.string("history.storage.title")) {
                    Text(ByteCountFormatter.string(fromByteCount: history.storageSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Button(L10n.string("history.export"), action: exportCSV)
                    .disabled(history.activeAccountKey == nil)
                Button(L10n.string("history.clear"), role: .destructive) { showsClearConfirmation = true }
                Text(L10n.string("history.storage.privacy")).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(history.isRestoring || history.needsRestart)
            HistoryBackupView(settings: settings, history: history)
        }
        .formStyle(.grouped)
        .task { await history.refreshMetadata() }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ClaudeMeter-History.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let data = try await history.exportCSV()
                    try data.write(to: url, options: .atomic)
                } catch { actionError = L10n.string("backup.failed") }
            }
        }
    }
}

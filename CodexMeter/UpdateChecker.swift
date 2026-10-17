import Combine
import Foundation

struct AvailableUpdate: Equatable, Identifiable {
    let version: String
    let title: String?
    let releaseNotes: String?
    let releasePageURL: URL
    let publishedAt: Date?

    var id: String { version }
}

/// Keeps update previews local until ClaudeMeter has its own signed release channel.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(AvailableUpdate)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var automaticallyInstallsUpdates = false
    @Published private(set) var isDeveloperPreview = false
    private var stateBeforeDeveloperPreview: State?

    init(includePrereleases: Bool = false) {}

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var allowsAutomaticUpdates: Bool { false }
    var canCheckForUpdates: Bool { false }

    func check(includePrereleases: Bool) {
        clearDeveloperPreview()
        state = .failed(L10n.string("updates.unavailable"))
    }

    func setIncludesPrereleases(_ includePrereleases: Bool) {}
    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {}
    func refreshPreferences() {}

    func showDeveloperUpdatePreview() {
        if !isDeveloperPreview { stateBeforeDeveloperPreview = state }
        isDeveloperPreview = true
        state = .updateAvailable(AvailableUpdate(
            version: "9.9.9",
            title: "ClaudeMeter 9.9.9 Preview",
            releaseNotes: nil,
            releasePageURL: URL(string: "about:blank")!,
            publishedAt: nil
        ))
    }

    func clearDeveloperPreview() {
        guard isDeveloperPreview else { return }
        isDeveloperPreview = false
        state = stateBeforeDeveloperPreview ?? .idle
        stateBeforeDeveloperPreview = nil
    }
}

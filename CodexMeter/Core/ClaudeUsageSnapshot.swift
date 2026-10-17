import Foundation

/// Last successful account-scoped quota, retaining the age of its recorded observations.
nonisolated struct ClaudeUsageSnapshot: Sendable {
    let windows: [CodexUsageWindow]
    let sampledAt: Date

    static func fromHistorySamples(_ samples: [QuotaHistorySample]) -> ClaudeUsageSnapshot? {
        let valid = samples.filter { sample in
            let parts = sample.windowID.split(separator: ":", maxSplits: 2)
            guard !sample.isStale, sample.source == .refresh,
                  (0...100).contains(sample.remainingPercent),
                  parts.count == 3, parts[0] == "duration",
                  let duration = Int(parts[1]), duration > 0,
                  duration == sample.windowDurationMins,
                  parts[2] == "claude" || parts[2].hasPrefix("claude-"),
                  sample.sampledAt.timeIntervalSince1970.isFinite else { return false }
            return sample.resetsAt?.timeIntervalSince1970.isFinite ?? true
        }
        guard let newest = valid.map(\.sampledAt).max() else { return nil }
        // Unchanged buckets are deduplicated until their 15-minute history anchor.
        let recent = valid.filter { newest.timeIntervalSince($0.sampledAt) <= 15 * 60 }
            .sorted {
                if $0.windowDurationMins != $1.windowDurationMins {
                    return ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
                }
                return $0.windowID < $1.windowID
            }
        let windows = recent.map { sample in
            let id: String
            switch sample.windowID {
            case "duration:300:claude": id = "claude-primary"
            case "duration:10080:claude": id = "claude-secondary"
            default: id = sample.windowID
            }
            return CodexUsageWindow(
                id: id, name: sample.windowName, usedPercent: 100 - sample.remainingPercent,
                windowDurationMins: sample.windowDurationMins, resetsAt: sample.resetsAt
            )
        }
        return ClaudeUsageSnapshot(windows: windows, sampledAt: recent.map(\.sampledAt).min()!)
    }
}

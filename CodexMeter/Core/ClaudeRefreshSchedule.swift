import Foundation

nonisolated struct ClaudeRefreshSchedule {
    static let foregroundInterval: TimeInterval = 300
    static let backgroundInterval: TimeInterval = 600
    static let manualMinimumInterval: TimeInterval = 60

    private(set) var lastAttempt: Date?
    private(set) var retryAfter: Date?
    private var failures = 0

    func mayRefresh(at now: Date, manual: Bool) -> Bool {
        guard retryAfter.map({ now >= $0 }) ?? true else { return false }
        guard manual, let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Self.manualMinimumInterval
    }

    mutating func started(at now: Date) {
        lastAttempt = now
    }

    mutating func succeeded() {
        failures = 0
        retryAfter = nil
    }

    mutating func failed(at now: Date, usageUnavailable: Bool) {
        failures = min(failures + 1, 5)
        let initialDelay: TimeInterval = usageUnavailable ? 300 : 20
        let maximumDelay: TimeInterval = usageUnavailable ? 1_800 : 300
        retryAfter = now.addingTimeInterval(min(maximumDelay, initialDelay * pow(2, Double(failures - 1))))
    }

    func nextAutomaticAttempt(isPopoverVisible: Bool) -> Date? {
        // Retry a failed request when its cooldown expires, independently of
        // whether the popover is open. Successful polling uses the normal interval.
        if let retryAfter { return retryAfter }
        return lastAttempt?.addingTimeInterval(isPopoverVisible ? Self.foregroundInterval : Self.backgroundInterval)
    }
}

import Foundation

nonisolated struct ClaudeAuthStatus: Decodable, Equatable, Sendable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let orgId: String?
    let subscriptionType: String?

    var supportsUsage: Bool {
        loggedIn && (authMethod == "claude.ai" || authMethod == "oauth_token")
            && (apiProvider == nil || apiProvider == "firstParty")
    }

    // Organization membership can have its own quota even for the same email.
    var historyIdentity: String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else { return nil }
        return "\(email.lowercased())|\(orgId ?? "")"
    }
}

nonisolated enum ClaudeCLIError: Error, Equatable {
    case notInstalled, notLoggedIn, subscriptionRequired, setupRequired
    case timedOut, communication, outputTooLarge, usageUnrecognized, cancelled

    var localizationKey: String {
        switch self {
        case .notInstalled: return "error.codex_not_found"
        case .notLoggedIn: return "error.not_logged_in"
        case .subscriptionRequired: return "error.claude_subscription_required"
        case .setupRequired: return "error.claude_setup_required"
        case .timedOut: return "error.request_timeout"
        case .usageUnrecognized: return "error.claude_usage_unrecognized"
        case .communication, .outputTooLarge, .cancelled: return "error.communication"
        }
    }
}

/// Parses Claude Code's screen-reader /usage panel; unknown values stay unknown.
nonisolated enum ClaudeUsageParser {
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B[()][A-Z0-9]|\x1B[78=>@-_]"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\x00-\x08\x0B\x0C\x0E-\x1F]"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func blockingError(in text: String) -> ClaudeCLIError? {
        let lower = clean(text).lowercased()
        if ["do you trust", "trust this folder", "ready to code here", "choose the text style",
            "enter selection", "select login method"].contains(where: lower.contains) {
            return .setupRequired
        }
        if lower.contains("not logged in") || lower.contains("please run /login") {
            return .notLoggedIn
        }
        if lower.contains("only available for") && lower.contains("subscriber") {
            return .subscriptionRequired
        }
        if ["showing last-known usage", "failed to load usage", "partial usage data",
            "per-model breakdown unavailable", "could not refresh usage", "usage endpoint is rate limited"]
            .contains(where: lower.contains) { return .usageUnrecognized }
        return nil
    }

    static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> [CodexUsageWindow]? {
        let clean = clean(text)
        guard blockingError(in: clean) == nil,
              let start = clean.range(of: "Current session", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let panel = String(clean[start.lowerBound...])
        // Claude's usage modal ends with its cancel hint. A quiet pipe alone can
        // also mean a partial render or a cached panel still refreshing.
        guard panel.range(of: #"(?im)\bEsc\s+to\s+cancel\s*$"#, options: .regularExpression) != nil,
              !panel.localizedCaseInsensitiveContains("Refreshing"),
              !panel.localizedCaseInsensitiveContains("Loading usage") else { return nil }
        let heading = try! NSRegularExpression(pattern: #"(?im)^\s*(Current session|Current week(?:\s*\([^)]+\))?)\s*$"#)
        let matches = heading.matches(in: panel, range: NSRange(panel.startIndex..., in: panel))
        var windows: [CodexUsageWindow] = []
        for (index, match) in matches.enumerated() {
            guard let labelRange = Range(match.range(at: 1), in: panel) else { return nil }
            let label = String(panel[labelRange])
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (panel as NSString).length
            var block = (panel as NSString).substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
            if let extra = block.range(of: #"(?im)^\s*(?:Extra usage|Usage credits|Claude Code and Cowork credit)\b"#, options: .regularExpression) {
                block = String(block[..<extra.lowerBound])
            }
            guard let percent = capture(#"(?i)([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(used|remaining|left)\b"#, in: block),
                  let value = Double(percent[0]), (0...100).contains(value) else { return nil }
            let used = percent[1].lowercased() == "used" ? value : 100 - value
            let session = label.lowercased() == "current session"
            let scope = capture(#"\(([^)]+)\)"#, in: label)?.first?.lowercased() ?? "all models"
            let slug = scope.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let id = session ? "claude-primary" : scope == "all models" ? "claude-secondary" : "claude-\(slug)-secondary"
            guard !windows.contains(where: { $0.id == id }) else { return nil }
            let minutes = session ? 300 : 10_080
            let reset = capture(#"(?im)^\s*Resets?\s+([^\n]+)"#, in: block)?.first
            windows.append(CodexUsageWindow(id: id, name: label, usedPercent: Int(used.rounded()),
                windowDurationMins: minutes, resetsAt: reset.flatMap {
                    resetDate($0, now: now, timeZone: timeZone, durationMinutes: minutes)
                }))
        }
        return windows.first?.id == "claude-primary" ? windows : nil
    }

    static func resetDate(_ text: String, now: Date, timeZone: TimeZone, durationMinutes: Int) -> Date? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var zone = timeZone
        if let namedZone = capture(#"\(([^)]+)\)\s*$"#, in: value)?.first {
            guard let parsedZone = TimeZone(identifier: namedZone) ?? TimeZone(abbreviation: namedZone) else { return nil }
            zone = parsedZone
            value = value.replacingOccurrences(of: #"\s*\([^)]+\)\s*$"#, with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"(?i)\s+at\s+"#, with: " ", options: .regularExpression)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.isLenient = false
        formatter.defaultDate = now
        let timeFormats = ["h:mma", "h:mm a", "ha", "h a", "HH:mm"]
        let dateFormats = ["MMM d h:mma", "MMM d h:mm a", "MMM d ha", "MMM d h a", "MMM d HH:mm",
                           "MMM d, h:mma", "MMM d, ha", "MMM d, HH:mm"]
        for format in timeFormats + dateFormats {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: value) else { continue }
            let units: Set<Calendar.Component> = timeFormats.contains(format) ? [.hour, .minute] : [.month, .day, .hour, .minute]
            let components = calendar.dateComponents(units, from: parsed)
            guard let result = calendar.nextDate(after: now.addingTimeInterval(-1), matching: components,
                matchingPolicy: .strict, repeatedTimePolicy: .first),
                  result.timeIntervalSince(now) <= Double(durationMinutes * 60) + 60 else { return nil }
            return result
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

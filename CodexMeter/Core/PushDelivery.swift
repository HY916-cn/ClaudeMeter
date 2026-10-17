import Foundation

enum PushChannel: String, CaseIterable, Identifiable, Sendable {
    case bark, gotify, telegram, discord
    var id: String { rawValue }
}

enum PushDeliveryFailure: String, Error, Equatable, Sendable {
    case invalidConfiguration, network, http, rejected
    var localizedKey: String {
        switch self {
        case .invalidConfiguration: return "settings.push.error.invalid_configuration"
        case .network: return "settings.push.error.network"
        case .http: return "settings.push.error.http"
        case .rejected: return "settings.push.error.rejected"
        }
    }
}

enum PushDeliveryStatus: Equatable, Sendable {
    case idle, sending, sent, failed(PushDeliveryFailure)
}

struct PushChannelConfiguration: Equatable, Sendable {
    var channel: PushChannel
    var serverURL: String = ""
    var credential: String = ""
    var target: String = ""
    var iconURL: String = ""
    var priority: Int = 5
}

enum PushRequestBuilder {
    static func request(configuration: PushChannelConfiguration, title: String, body: String) throws -> URLRequest {
        let credential = configuration.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw PushDeliveryFailure.invalidConfiguration }
        var url: URL
        var payload: [String: Any]
        switch configuration.channel {
        case .bark:
            var components = try endpoint(configuration.serverURL)
            let keyPath = credential.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            if components.path.split(separator: "/").last.map(String.init) != credential {
                let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                components.percentEncodedPath = base.isEmpty ? "/\(keyPath)" : "/\(base)/\(keyPath)"
            }
            guard let endpointURL = components.url else { throw PushDeliveryFailure.invalidConfiguration }
            url = endpointURL
            payload = ["title": title, "body": body, "group": "ClaudeMeter", "isArchive": "1"]
            let icon = configuration.iconURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !icon.isEmpty {
                guard let image = URLComponents(string: icon), image.scheme?.lowercased() == "https",
                      let host = image.host, !host.isEmpty, image.user == nil, image.password == nil else {
                    throw PushDeliveryFailure.invalidConfiguration
                }
                payload["icon"] = icon
            }
        case .gotify:
            var components = try endpoint(configuration.serverURL)
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = path.hasSuffix("message") && path.split(separator: "/").last == "message"
                ? "/" + path : (path.isEmpty ? "/message" : "/" + path + "/message")
            guard let endpointURL = components.url else { throw PushDeliveryFailure.invalidConfiguration }
            url = endpointURL
            payload = ["title": title, "message": body, "priority": min(10, max(0, configuration.priority))]
        case .telegram:
            guard credential.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw PushDeliveryFailure.invalidConfiguration
            }
            let target = configuration.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { throw PushDeliveryFailure.invalidConfiguration }
            url = URL(string: "https://api.telegram.org/bot\(credential)/sendMessage")!
            payload = ["chat_id": target, "text": "\(title)\n\(body)"]
        case .discord:
            var components = try endpoint(credential)
            let allowedHosts = ["discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com"]
            let segments = components.path.split(separator: "/")
            guard allowedHosts.contains(components.host?.lowercased() ?? ""),
                  components.port == nil || components.port == 443,
                  segments.count == 4 || segments.count == 5,
                  segments.first == "api",
                  segments.count == 4 || segments[1].range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil,
                  segments[segments.count - 3] == "webhooks",
                  segments[segments.count - 2].allSatisfy(\.isNumber), !segments.last!.isEmpty else {
                throw PushDeliveryFailure.invalidConfiguration
            }
            components.queryItems = [URLQueryItem(name: "wait", value: "true")]
            guard let endpointURL = components.url else { throw PushDeliveryFailure.invalidConfiguration }
            url = endpointURL
            payload = ["content": "\(title)\n\(body)", "allowed_mentions": ["parse": [String]()]]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if configuration.channel == .gotify { request.setValue(credential, forHTTPHeaderField: "X-Gotify-Key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func endpoint(_ value: String) throws -> URLComponents {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw PushDeliveryFailure.invalidConfiguration
        }
        return components
    }
}

struct PushDeliveryOutcome: Equatable, Sendable {
    var failure: PushDeliveryFailure?
    var retryable: Bool = false
    var retryAfter: TimeInterval?

    static func evaluate(channel: PushChannel, statusCode: Int?, data: Data?, networkError: Bool,
                         retryAfterHeader: String? = nil) -> Self {
        if networkError { return Self(failure: .network, retryable: true) }
        guard let statusCode else { return Self(failure: .network, retryable: true) }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let retryAfter = retryAfterHeader.flatMap(Double.init)
            ?? (json?["parameters"] as? [String: Any])?["retry_after"] as? Double
            ?? json?["retry_after"] as? Double
        if statusCode == 429 || (500...599).contains(statusCode) {
            return Self(failure: .http, retryable: true, retryAfter: retryAfter)
        }
        guard (200...299).contains(statusCode) else { return Self(failure: .http) }
        switch channel {
        case .telegram:
            guard json?["ok"] as? Bool == true else {
                let code = json?["error_code"] as? Int
                return Self(failure: .rejected, retryable: code == 429 || code.map { (500...599).contains($0) } == true,
                            retryAfter: retryAfter)
            }
        case .bark:
            guard json?["code"] as? Int == 200 else { return Self(failure: .rejected) }
        case .gotify:
            guard let id = json?["id"] as? Int, id > 0 else { return Self(failure: .rejected) }
        case .discord:
            guard let id = json?["id"] as? String, !id.isEmpty, id.allSatisfy(\.isNumber) else {
                return Self(failure: .rejected)
            }
        }
        return Self(failure: nil)
    }
}

enum PushRetryPolicy {
    static let maximumAttempts = 3
    static func delay(afterAttempt attempt: Int, outcome: PushDeliveryOutcome) -> TimeInterval? {
        guard outcome.retryable, attempt < maximumAttempts else { return nil }
        let delay = outcome.retryAfter ?? (attempt == 1 ? 2 : 5)
        return delay.isFinite ? min(60, max(1, delay)) : 60
    }
}

/// Each account generation owns a bounded set of claimed events. Cancellation invalidates old callbacks.
struct PushDeliveryLedger {
    private(set) var generation = UUID()
    private var events: [String] = []
    mutating func claim(eventID: String, channel: PushChannel) -> Bool {
        let key = "\(channel.rawValue):\(eventID)"
        guard !events.contains(key) else { return false }
        events.append(key)
        if events.count > 128 { events.removeFirst() }
        return true
    }
    mutating func reset() { generation = UUID(); events.removeAll() }
    func accepts(_ generation: UUID) -> Bool { self.generation == generation }
}

import Foundation
import Security

enum PushCredential: String, CaseIterable {
    case barkDeviceKey
    case gotifyAppToken
    case telegramBotToken
    case discordWebhookURL

    var legacyDefaultsKey: String { "push.\(rawValue)" }
}

protocol PushCredentialBackend {
    func read(_ credential: PushCredential) throws -> String?
    func save(_ value: String, for credential: PushCredential) throws
}

struct PushCredentialLoadResult {
    let value: String
    let failed: Bool
}

/// Keeps credential migration recoverable if the login Keychain is locked or access is denied.
final class PushCredentialStore {
    private let backend: any PushCredentialBackend
    private let defaults: UserDefaults

    init(defaults: UserDefaults, backend: any PushCredentialBackend) {
        self.defaults = defaults
        self.backend = backend
    }

    func load(_ credential: PushCredential) -> PushCredentialLoadResult {
        let legacyValue = defaults.string(forKey: credential.legacyDefaultsKey)
        do {
            let storedValue = try backend.read(credential)
            let value = storedValue ?? legacyValue ?? ""
            if legacyValue != nil {
                // Prefer an existing secure value over a potentially stale legacy preference.
                do {
                    try save(value, for: credential)
                } catch {
                    return PushCredentialLoadResult(value: value, failed: true)
                }
            }
            return PushCredentialLoadResult(value: value, failed: false)
        } catch {
            return PushCredentialLoadResult(value: legacyValue ?? "", failed: true)
        }
    }

    func save(_ value: String, for credential: PushCredential) throws {
        try backend.save(value, for: credential)
        defaults.removeObject(forKey: credential.legacyDefaultsKey)
    }
}

struct KeychainPushCredentialBackend: PushCredentialBackend {
    // Do not depend on a Debug/Release bundle ID or a signing-team access-group entitlement.
    // The login Keychain uses its normal application ACL; re-signed ad-hoc updates may
    // require macOS access approval. Denials are surfaced without discarding legacy data.
    static let service = "com.huang.ClaudeMeter.pushCredentials"

    func read(_ credential: PushCredential) throws -> String? {
        var query = baseQuery(credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: errSecDecode)
        }
        return value
    }

    func save(_ value: String, for credential: PushCredential) throws {
        let query = baseQuery(credential)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainFailure(status: status)
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainFailure(status: updateStatus) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
    }

    private func baseQuery(_ credential: PushCredential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credential.rawValue
        ]
    }

    private struct KeychainFailure: Error {
        let status: OSStatus
    }
}

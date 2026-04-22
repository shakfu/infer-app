import Foundation
import Security

/// Keychain-backed storage for cloud provider API keys. One generic-password
/// item per provider. Sibling to `Vault.swift` — deliberately separate so
/// vault/transcript concerns don't mix with credential handling.
///
/// Uses the data-protection keychain (`kSecUseDataProtectionKeychain: true`)
/// rather than the legacy login keychain. Items are then scoped to this app's
/// code signature: other processes cannot request access via the user-consent
/// dialog, and the items do not appear in Keychain Access.app.
enum APIKeyStore {
    private static let service = "com.infer.apikey"

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s): return "Keychain error (\(s))"
            case .encodingFailed: return "Could not encode API key"
            }
        }
    }

    /// Base query common to every operation. Must match exactly across add /
    /// update / read / delete, or the OS treats them as different items.
    private static func baseQuery(for provider: CloudProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func set(_ key: String, for provider: CloudProvider) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let query = baseQuery(for: provider)
        // `SecItemUpdate` doesn't upsert, so try update first and fall back to add.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    static func get(for provider: CloudProvider) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasKey(for provider: CloudProvider) -> Bool {
        get(for: provider) != nil
    }

    static func clear(for provider: CloudProvider) {
        _ = SecItemDelete(baseQuery(for: provider) as CFDictionary)
    }

    /// Resolve the active key for a provider: Keychain first, then the
    /// corresponding process environment variable as a developer fallback.
    /// Returns `(key, source)` so the UI can render "Using env var" when
    /// applicable.
    static func resolve(for provider: CloudProvider) -> (key: String, source: Source)? {
        if let k = get(for: provider) { return (k, .keychain) }
        if let env = ProcessInfo.processInfo.environment[provider.envVarName],
           !env.isEmpty {
            return (env, .envVar)
        }
        return nil
    }

    enum Source: Equatable {
        case keychain
        case envVar
    }
}

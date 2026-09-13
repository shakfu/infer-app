import Foundation
import Security

/// Keychain-backed storage for cloud provider API keys. One generic-password
/// item per provider (and per compat-endpoint name). Sibling to `Vault.swift`
/// — deliberately separate so vault/transcript concerns don't mix with
/// credential handling.
///
/// Uses the data-protection keychain (`kSecUseDataProtectionKeychain: true`)
/// rather than the legacy login keychain. Items are then scoped to this app's
/// code signature: other processes cannot request access via the user-consent
/// dialog, and the items do not appear in Keychain Access.app.
///
/// Ad-hoc-signed builds (`make bundle`, `swift test`, `infer-cli`) lack the
/// entitlement that keychain requires, and every write fails with
/// `errSecMissingEntitlement` (-34018). Those builds fall back to the login
/// keychain. There, items are visible in Keychain Access.app and macOS may
/// ask to allow access after each rebuild, because the ad-hoc signature
/// changes. Reads and deletes consult both keychains.
public enum APIKeyStore {
    static let service = "com.infer.apikey"

    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s): return "Keychain error (\(s))"
            case .encodingFailed: return "Could not encode API key"
            }
        }
    }

    /// Base query common to every operation. Must match exactly across add /
    /// update / read / delete, or the OS treats them as different items.
    private static func baseQuery(
        service: String,
        account: String,
        dataProtection: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public static func set(_ key: String, for provider: CloudProvider) throws {
        try set(key, service: service, account: provider.keychainAccount)
    }

    public static func get(for provider: CloudProvider) -> String? {
        get(service: service, account: provider.keychainAccount)
    }

    public static func hasKey(for provider: CloudProvider) -> Bool {
        get(for: provider) != nil
    }

    public static func clear(for provider: CloudProvider) {
        clear(service: service, account: provider.keychainAccount)
    }

    // Service-parameterized so tests can use a throwaway service name.

    static func set(_ key: String, service: String, account: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.encodingFailed }
        var status = upsert(data, query: baseQuery(service: service, account: account, dataProtection: true))
        if status == errSecMissingEntitlement {
            status = upsert(data, query: baseQuery(service: service, account: account, dataProtection: false))
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func get(service: String, account: String) -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(service: service, account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    static func clear(service: String, account: String) {
        for dataProtection in [true, false] {
            _ = SecItemDelete(baseQuery(service: service, account: account, dataProtection: dataProtection) as CFDictionary)
        }
    }

    /// `SecItemUpdate` doesn't upsert, so update first and fall back to add.
    private static func upsert(_ data: Data, query: [String: Any]) -> OSStatus {
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Resolve the active key for a provider: Keychain first, then the
    /// corresponding process environment variable as a developer fallback.
    /// Returns `(key, source)` so the caller can render "Using env var" in
    /// the UI **and** log a warning to the Console — env vars are visible
    /// to other processes running as the same user (`ps -E`) and leak into
    /// child processes by default, so silent fallback would hide a
    /// non-trivial credential-exposure surface from the user.
    ///
    /// Compat providers don't have a canonical env var (`envVarName == nil`)
    /// and resolve only against the keychain.
    public static func resolve(for provider: CloudProvider) -> (key: String, source: Source)? {
        if let k = get(for: provider) { return (k, .keychain) }
        if let envVar = provider.envVarName,
           let env = ProcessInfo.processInfo.environment[envVar],
           !env.isEmpty {
            return (env, .envVar)
        }
        return nil
    }

    public enum Source: Equatable, Sendable {
        case keychain
        case envVar
    }
}

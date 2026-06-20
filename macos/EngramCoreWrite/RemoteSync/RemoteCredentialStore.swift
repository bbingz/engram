import Foundation
import Security

/// Keychain-backed store for the remote-offload bearer token. The token is a
/// secret, so it lives in the Keychain — never in `settings.json` (the non-secret
/// server URL may live in settings). `kSecAttrAccessibleAfterFirstUnlock` lets the
/// background service read it without UI after the user's first login unlock.
public enum RemoteCredentialStore {
    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    private static let service = "com.engram.remote-offload"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func saveToken(_ token: String, account: String = "default") throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func loadToken(account: String = "default") -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func deleteToken(account: String = "default") -> Bool {
        SecItemDelete(baseQuery(account: account) as CFDictionary) == errSecSuccess
    }
}

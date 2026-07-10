import Darwin
import Foundation
import Security

/// Injectable secret-store surface used by `EmbeddingSettings` migration/load and
/// the app `KeychainHelper` UI facade. Production uses `KeychainSecretStore`;
/// tests inject an in-memory double.
public protocol KeychainSecretStoring: Sendable {
    func get(_ account: String) -> String?
    @discardableResult
    func set(_ account: String, value: String) -> Bool
    func delete(_ account: String)
}

/// Shared Security-framework operations for generic password items under the
/// Engram Keychain service. App UI continues to go through `KeychainHelper`,
/// which owns debug/unsigned-build skip policy and delegates here.
public enum KeychainSecretStore {
    public static let service = "com.engram.app"

    public enum Account {
        public static let embeddingApiKey = "embeddingApiKey"
        public static let aiApiKey = "aiApiKey"
        public static let titleApiKey = "titleApiKey"
    }

    public static let shared: any KeychainSecretStoring = LiveKeychainSecretStore(service: service)

    public static func get(_ account: String, service: String = service) -> String? {
        LiveKeychainSecretStore(service: service).get(account)
    }

    @discardableResult
    public static func set(_ account: String, value: String, service: String = service) -> Bool {
        LiveKeychainSecretStore(service: service).set(account, value: value)
    }

    public static func delete(_ account: String, service: String = service) {
        LiveKeychainSecretStore(service: service).delete(account)
    }
}

public struct LiveKeychainSecretStore: KeychainSecretStoring, Sendable {
    public let service: String

    public init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    public func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess { return true }

        // Another process may have inserted the item after our update miss.
        if status == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, updates as CFDictionary) == errSecSuccess
        }
        return false
    }

    public func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Cross-process advisory lock for the shared Engram settings file.
public enum EngramSettingsFileLock {
    private static let processLock = NSLock()

    public static func withExclusiveLock<T>(
        for settingsURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        let lockURL = settingsURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }

        return try operation()
    }
}

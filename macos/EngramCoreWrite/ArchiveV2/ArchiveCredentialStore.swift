import Foundation
import Security

public enum ArchiveCredentialStoreError: Error, Equatable, Sendable {
    case invalidReplicaID
    case invalidToken
    case keychainStatus(OSStatus)
}

protocol ArchiveCredentialKeychainOperations: Sendable {
    func update(service: String, account: String, value: Data) -> OSStatus
    func add(service: String, account: String, value: Data) -> OSStatus
    func copy(service: String, account: String) -> (OSStatus, Data?)
}

public struct ArchiveCredentialStore: ArchiveReplicaTokenLoading, Sendable {
    public static let service = "com.engram.remote-archive-v2"
    private let operations: any ArchiveCredentialKeychainOperations

    public init() {
        operations = LiveArchiveCredentialKeychainOperations()
    }

    init(operations: any ArchiveCredentialKeychainOperations) {
        self.operations = operations
    }

    public func saveToken(_ token: String, replicaID: String) throws {
        let account = try Self.account(for: replicaID)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchiveCredentialStoreError.invalidToken
        }
        let data = Data(token.utf8)
        let updateStatus = operations.update(
            service: Self.service,
            account: account,
            value: data
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ArchiveCredentialStoreError.keychainStatus(updateStatus)
        }

        let addStatus = operations.add(
            service: Self.service,
            account: account,
            value: data
        )
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let racedUpdateStatus = operations.update(
                service: Self.service,
                account: account,
                value: data
            )
            guard racedUpdateStatus == errSecSuccess else {
                throw ArchiveCredentialStoreError.keychainStatus(racedUpdateStatus)
            }
            return
        }
        throw ArchiveCredentialStoreError.keychainStatus(addStatus)
    }

    public func loadToken(replicaID: String) throws -> String? {
        let account = try Self.account(for: replicaID)
        let (status, data) = operations.copy(service: Self.service, account: account)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ArchiveCredentialStoreError.keychainStatus(status)
        }
        guard let data,
              let token = String(data: data, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchiveCredentialStoreError.invalidToken
        }
        return token
    }

    private static func account(for replicaID: String) throws -> String {
        guard replicaID == "hq" || replicaID == "m1" else {
            throw ArchiveCredentialStoreError.invalidReplicaID
        }
        return "replica:\(replicaID)"
    }
}

private struct LiveArchiveCredentialKeychainOperations: ArchiveCredentialKeychainOperations {
    func update(service: String, account: String, value: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updates: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemUpdate(query as CFDictionary, updates as CFDictionary)
    }

    func add(service: String, account: String, value: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
}

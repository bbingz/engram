// macos/Engram/Views/Settings/SettingsIO.swift
import Foundation
import Security

let engramSettingsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".engram/settings.json")

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.engram.app"

    /// Debug/ad-hoc builds skip Keychain to avoid authorization dialogs.
    /// Detection: if the binary runs from DerivedData (Xcode build) or is not
    /// properly code-signed, Keychain access will prompt — so we skip it.
    private static let isUnsignedBuild: Bool = {
        // Check if running from Xcode DerivedData (always true for debug builds)
        let path = Bundle.main.bundlePath
        if path.contains("DerivedData") { return true }

        // Check if app has a valid code signature with keychain-access-groups entitlement
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let staticCode = code else { return true }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(staticCode, flags, nil) != errSecSuccess
    }()

    static func get(_ key: String) -> String? {
        if isUnsignedBuild { return nil }  // Skip Keychain in Debug — use plaintext JSON fallback
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Save a value to the Keychain. Returns true on success.
    @discardableResult
    static func set(_ key: String, value: String) -> Bool {
        if isUnsignedBuild { return false }  // Skip Keychain in Debug
        guard let data = value.data(using: .utf8) else { return false }
        delete(key)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func delete(_ key: String) {
        if isUnsignedBuild { return }  // Skip Keychain in Debug
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - One-time migration from plaintext JSON to Keychain

func migrateKeysToKeychainIfNeeded() {
    guard let settings = readEngramSettings() else { return }
    let keysToMigrate: [(jsonKey: String, keychainKey: String)] = [
        ("aiApiKey", "aiApiKey"),
        ("titleApiKey", "titleApiKey"),
    ]
    var needsSave = false
    var mutable = settings
    for entry in keysToMigrate {
        guard let value = mutable[entry.jsonKey] as? String, !value.isEmpty else { continue }
        if value == "@keychain" { continue }  // already migrated
        if KeychainHelper.get(entry.keychainKey) == nil {
            KeychainHelper.set(entry.keychainKey, value: value)
            guard KeychainHelper.get(entry.keychainKey) == value else { continue }  // verify read-back
        }
        mutable[entry.jsonKey] = "@keychain"
        needsSave = true
    }
    // Viking API key is nested
    if var viking = mutable["viking"] as? [String: Any],
       let vKey = viking["apiKey"] as? String, !vKey.isEmpty, vKey != "@keychain" {
        if KeychainHelper.get("vikingApiKey") == nil {
            KeychainHelper.set("vikingApiKey", value: vKey)
            guard KeychainHelper.get("vikingApiKey") == vKey else { return }
        }
        viking["apiKey"] = "@keychain"
        mutable["viking"] = viking
        needsSave = true
    }
    if needsSave {
        if let data = try? JSONSerialization.data(withJSONObject: mutable, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: engramSettingsPath)
        }
    }
}

func readEngramSettings() -> [String: Any]? {
    guard let data = try? Data(contentsOf: engramSettingsPath),
          let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return settings
}

func mutateEngramSettings(_ transform: (inout [String: Any]) -> Void) {
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: engramSettingsPath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = existing
    }
    transform(&settings)
    if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: engramSettingsPath)
    }
}

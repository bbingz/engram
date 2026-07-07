// macos/Engram/Views/Settings/SettingsIO.swift
import Foundation
import Security

let engramSettingsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".engram/settings.json")

func repairEngramSettingsPermissionsIfPresent(at url: URL = engramSettingsPath) throws {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    if fileManager.fileExists(atPath: directory.path) {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    if fileManager.fileExists(atPath: url.path) {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

func writeEngramSettingsDataSecurely(_ data: Data, to url: URL = engramSettingsPath) throws {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try data.write(to: url, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

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
    if needsSave {
        if let data = try? JSONSerialization.data(withJSONObject: mutable, options: [.prettyPrinted, .sortedKeys]) {
            try? writeEngramSettingsDataSecurely(data)
        }
    }
}

func readEngramSettings() -> [String: Any]? {
    try? repairEngramSettingsPermissionsIfPresent()
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
        try? writeEngramSettingsDataSecurely(data)
    }
}

struct UsageTokenLimitSettings: Equatable {
    struct Limit: Equatable {
        var fiveHourTokens: Double?
        var weeklyTokens: Double?
    }

    private var sourceLimits: [String: Limit]

    var sourceIDs: [String] {
        sourceLimits.keys.sorted()
    }

    var codexFiveHourTokens: Double? { limit(for: "codex")?.fiveHourTokens }
    var codexWeeklyTokens: Double? { limit(for: "codex")?.weeklyTokens }
    var claudeFiveHourTokens: Double? { limit(for: "claude-code")?.fiveHourTokens }
    var claudeWeeklyTokens: Double? { limit(for: "claude-code")?.weeklyTokens }

    init(
        codexFiveHourTokens: Double? = nil,
        codexWeeklyTokens: Double? = nil,
        claudeFiveHourTokens: Double? = nil,
        claudeWeeklyTokens: Double? = nil
    ) {
        self.init(sourceLimits: [
            "codex": Limit(
                fiveHourTokens: Self.positive(codexFiveHourTokens),
                weeklyTokens: Self.positive(codexWeeklyTokens)
            ),
            "claude-code": Limit(
                fiveHourTokens: Self.positive(claudeFiveHourTokens),
                weeklyTokens: Self.positive(claudeWeeklyTokens)
            ),
        ])
    }

    init(sourceLimits: [String: Limit]) {
        self.sourceLimits = sourceLimits.reduce(into: [:]) { result, pair in
            let sourceID = Self.normalizedSourceID(pair.key)
            guard !sourceID.isEmpty else { return }
            let limit = Limit(
                fiveHourTokens: Self.positive(pair.value.fiveHourTokens),
                weeklyTokens: Self.positive(pair.value.weeklyTokens)
            )
            guard limit.fiveHourTokens != nil || limit.weeklyTokens != nil else { return }
            result[sourceID] = limit
        }
    }

    init(settingsObject: [String: Any]) {
        sourceLimits = Self.sanitizedSources(from: settingsObject)
    }

    func limit(for sourceID: String) -> Limit? {
        sourceLimits[Self.normalizedSourceID(sourceID)]
    }

    func settingsObject() -> [String: [String: Double]] {
        sourceLimits.reduce(into: [:]) { result, pair in
            if let source = sourceObject(limit: pair.value) {
                result[pair.key] = source
            }
        }
    }

    func settingsObject(preservingUnknownFrom existingObject: [String: Any]?) -> [String: [String: Double]] {
        var object: [String: [String: Double]] = [:]
        if let existingObject {
            object = Self.sanitizedSources(from: existingObject).reduce(into: [:]) { result, pair in
                if let source = UsageTokenLimitSettings(sourceLimits: [pair.key: pair.value]).settingsObject()[pair.key] {
                    result[pair.key] = source
                }
            }
        }
        settingsObject().forEach { sourceID, source in
            object[sourceID] = source
        }
        return object
    }

    private func sourceObject(limit: Limit) -> [String: Double]? {
        var source: [String: Double] = [:]
        if let fiveHourTokens = limit.fiveHourTokens { source["fiveHourTokens"] = fiveHourTokens }
        if let weeklyTokens = limit.weeklyTokens { source["weeklyTokens"] = weeklyTokens }
        return source.isEmpty ? nil : source
    }

    private static func sanitizedSources(from object: [String: Any]) -> [String: Limit] {
        object.reduce(into: [:]) { result, pair in
            let sourceID = normalizedSourceID(pair.key)
            guard !sourceID.isEmpty else { return }
            guard let sourceObject = pair.value as? [String: Any] else { return }
            let limit = Limit(
                fiveHourTokens: number(sourceObject["fiveHourTokens"]),
                weeklyTokens: number(sourceObject["weeklyTokens"])
            )
            if limit.fiveHourTokens != nil || limit.weeklyTokens != nil {
                result[sourceID] = limit
            }
        }
    }

    private static func normalizedSourceID(_ sourceID: String) -> String {
        sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return positive(double) }
        if let int = value as? Int { return positive(Double(int)) }
        if let number = value as? NSNumber { return positive(number.doubleValue) }
        return nil
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

// MARK: - One-time scrub of deprecated settings keys

/// Settings keys + Keychain accounts kept around for users upgrading from a
/// version that wrote them, but whose backing feature has been removed.
/// Add new entries here whenever a setting/feature is retired.
enum DeprecatedSettings {
    static let jsonKeys: [String] = ["viking", "syncNodeName", "syncEnabled", "embedding"]
    static let keychainAccounts: [String] = ["vikingApiKey"]

    /// Removes deprecated keys from the given settings dict in place.
    /// Returns true if any key was removed.
    @discardableResult
    static func scrub(_ settings: inout [String: Any]) -> Bool {
        var changed = false
        for key in jsonKeys where settings.removeValue(forKey: key) != nil {
            changed = true
        }
        return changed
    }
}

/// Idempotent: removes settings.json keys + Keychain entries left behind by
/// features that have been removed from the codebase. Safe to call on every launch.
func removeDeprecatedSettingsKeysIfNeeded() {
    for account in DeprecatedSettings.keychainAccounts where KeychainHelper.get(account) != nil {
        KeychainHelper.delete(account)
    }
    guard var settings = readEngramSettings() else { return }
    guard DeprecatedSettings.scrub(&settings) else { return }
    if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
        try? writeEngramSettingsDataSecurely(data)
    }
}

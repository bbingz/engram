// macos/Engram/Views/Settings/SettingsIO.swift
import Foundation

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
    try prepareEngramSettingsDirectory(for: url, fileManager: fileManager)

    try EngramSettingsFileLock.withExclusiveLock(for: url) {
        try writeEngramSettingsDataSecurelyUnlocked(data, to: url, fileManager: fileManager)
    }
}

private func prepareEngramSettingsDirectory(for url: URL, fileManager: FileManager) throws {
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
}

private func writeEngramSettingsDataSecurelyUnlocked(
    _ data: Data,
    to url: URL,
    fileManager: FileManager
) throws {
    let directory = url.deletingLastPathComponent()
    let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try? fileManager.removeItem(at: tempURL)
    guard fileManager.createFile(
        atPath: tempURL.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
    if fileManager.fileExists(atPath: url.path) {
        _ = try fileManager.replaceItemAt(
            url,
            withItemAt: tempURL,
            options: [.usingNewMetadataOnly]
        )
    } else {
        try fileManager.moveItem(at: tempURL, to: url)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

// MARK: - Keychain Helper

/// App UI facade over shared `KeychainSecretStore`. Keeps the development-build
/// skip policy local so Xcode runs never prompt for Keychain authorization.
enum KeychainHelper {
    /// Debug and Xcode-produced builds skip Keychain to avoid authorization dialogs.
    /// Installed Release builds use Keychain without synchronously revalidating
    /// their own code signature on the main thread.
    private static let shouldBypassKeychain: Bool = {
        #if DEBUG
        return true
        #else
        let path = Bundle.main.bundlePath
        return path.contains("DerivedData")
        #endif
    }()

    /// SEC-M3: only DEBUG/DerivedData may persist API keys as plaintext in settings.json.
    static var allowsPlaintextSettingsFallback: Bool { shouldBypassKeychain }

    static func get(_ key: String) -> String? {
        if shouldBypassKeychain { return nil }  // Use plaintext JSON fallback in development builds
        return KeychainSecretStore.get(key)
    }

    /// Save a value to the Keychain. Returns true on success.
    @discardableResult
    static func set(_ key: String, value: String) -> Bool {
        if shouldBypassKeychain { return false }
        return KeychainSecretStore.set(key, value: value)
    }

    static func delete(_ key: String) {
        if shouldBypassKeychain { return }
        KeychainSecretStore.delete(key)
    }
}

// MARK: - One-time migration from plaintext JSON to Keychain

func migrateKeysToKeychainIfNeeded() {
    let keysToMigrate: [(jsonKey: String, keychainKey: String)] = [
        ("aiApiKey", KeychainSecretStore.Account.aiApiKey),
        ("titleApiKey", KeychainSecretStore.Account.titleApiKey),
        ("embeddingApiKey", KeychainSecretStore.Account.embeddingApiKey),
    ]
    mutateEngramSettingsIfNeeded { settings in
        var changed = false
        for entry in keysToMigrate {
            guard let value = settings[entry.jsonKey] as? String, !value.isEmpty else { continue }
            if value == "@keychain" { continue }
            if KeychainHelper.get(entry.keychainKey) != value {
                guard KeychainHelper.set(entry.keychainKey, value: value) else { continue }
                guard KeychainHelper.get(entry.keychainKey) == value else { continue }
            }
            settings[entry.jsonKey] = "@keychain"
            changed = true
        }
        return changed
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
    mutateEngramSettingsIfNeeded { settings in
        transform(&settings)
        return true
    }
}

private func mutateEngramSettingsIfNeeded(
    at url: URL = engramSettingsPath,
    _ transform: (inout [String: Any]) -> Bool
) {
    let fileManager = FileManager.default
    guard (try? prepareEngramSettingsDirectory(for: url, fileManager: fileManager)) != nil else { return }
    try? EngramSettingsFileLock.withExclusiveLock(for: url) {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }
        guard transform(&settings) else { return }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try writeEngramSettingsDataSecurelyUnlocked(data, to: url, fileManager: fileManager)
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
    mutateEngramSettingsIfNeeded { settings in
        DeprecatedSettings.scrub(&settings)
    }
}

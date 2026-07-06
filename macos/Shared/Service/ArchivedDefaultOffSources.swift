import Foundation

/// Source ids whose adapters remain shipped but are default-off because the
/// sources are dormant local archives. Users can re-enable them from Sources.
enum ArchivedDefaultOffSources {
    static let orderedIDs = ["cline", "iflow", "lobsterai"]
    static let ids = Set(orderedIDs)
    static let settingsMigrationKey = "archivedDefaultOffSourcesMigrated"

    static func contains(_ source: String) -> Bool {
        ids.contains(source)
    }
}

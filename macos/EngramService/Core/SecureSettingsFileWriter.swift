import EngramCoreRead
import Foundation

/// Atomic settings-file writer for service-owned create/update paths.
/// Writes to a temporary file with POSIX 0600, then renames into place and
/// re-asserts 0600 on the final path so existing broader modes are repaired.
enum SecureSettingsFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try prepareDirectory(for: url, fileManager: fileManager)

        try EngramSettingsFileLock.withExclusiveLock(for: url) {
            try writeUnlocked(data, to: url, fileManager: fileManager)
        }
    }

    static func mutateJSON(
        at url: URL,
        _ transform: (inout [String: Any]) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        try prepareDirectory(for: url, fileManager: fileManager)
        try EngramSettingsFileLock.withExclusiveLock(for: url) {
            var object: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = parsed
            }
            try transform(&object)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try writeUnlocked(data, to: url, fileManager: fileManager)
        }
    }

    private static func prepareDirectory(for url: URL, fileManager: FileManager) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func writeUnlocked(_ data: Data, to url: URL, fileManager: FileManager) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
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
}

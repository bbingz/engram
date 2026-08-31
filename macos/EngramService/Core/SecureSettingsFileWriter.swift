import Darwin
import EngramCoreRead
import Foundation

/// Atomic settings-file writer for service-owned create/update paths.
/// Writes to a temporary file with POSIX 0600, then renames into place and
/// re-asserts 0600 on the final path so existing broader modes are repaired.
enum SecureSettingsFileWriter {
    private static let maximumSettingsBytes = 1024 * 1024

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
            if try nodeExists(at: url) {
                guard let data = SecureRegularFile.read(
                    atPath: url.path,
                    maximumBytes: maximumSettingsBytes,
                    repairPermissions: true
                ),
                    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                object = parsed
            }
            try transform(&object)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try writeUnlocked(data, to: url, fileManager: fileManager)
        }
    }

    private static func prepareDirectory(for url: URL, fileManager: FileManager) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              fchmod(descriptor, 0o700) == 0
        else {
            throw CocoaError(.fileReadNoPermission)
        }
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

        if try nodeExists(at: url) {
            guard SecureRegularFile.read(
                atPath: url.path,
                maximumBytes: maximumSettingsBytes,
                repairPermissions: true
            ) != nil else {
                throw CocoaError(.fileReadNoPermission)
            }
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: tempURL,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
        guard SecureRegularFile.read(
            atPath: url.path,
            maximumBytes: max(maximumSettingsBytes, data.count)
        ) != nil else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func nodeExists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw CocoaError(.fileReadUnknown)
    }
}

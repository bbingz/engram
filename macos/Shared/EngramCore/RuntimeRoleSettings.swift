import Darwin
import Foundation

/// The effective host role. Invalid settings never grant local-index access.
public enum EngramRuntimeRole: Equatable, Sendable {
    case local
    case collector
    case index
    case replica
    case invalidSettings

    public var allowsLocalIndex: Bool { self == .local || self == .index }

    public var unavailableMessage: String {
        if self == .invalidSettings {
            return "Engram runtimeRole settings are invalid or unreadable. Fix owner-only settings.json before using the local index."
        }
        return "This host runtimeRole does not provide a local index. Use the HQ Web reader or configure runtimeRole on an indexing host."
    }
}

public enum RuntimeRoleSettings {
    public static let maximumBytes = 1024 * 1024

    public static func settingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["ENGRAM_SETTINGS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let fixedHome = environment["CFFIXED_USER_HOME"], !fixedHome.isEmpty {
            return URL(fileURLWithPath: fixedHome).appendingPathComponent(".engram/settings.json")
        }
        if environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("engram-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent(".engram/settings.json")
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent(".engram/settings.json")
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EngramRuntimeRole {
        load(at: settingsURL(environment: environment))
    }

    public static func load(at url: URL) -> EngramRuntimeRole {
        guard let data = SecureRegularFile.read(
            atPath: url.path, maximumBytes: maximumBytes, repairPermissions: false
        ) else {
            return isDefinitelyMissing(url) ? .local : .invalidSettings
        }
        guard let document = try? JSONSerialization.jsonObject(with: data),
              let settings = document as? [String: Any] else {
            return .invalidSettings
        }
        guard let value = settings["runtimeRole"] else { return .local }
        guard let role = value as? String else { return .invalidSettings }
        switch role {
        case "local": return .local
        case "collector": return .collector
        case "index": return .index
        case "replica": return .replica
        default: return .invalidSettings
        }
    }

    /// A failed secure read is not evidence that settings are absent. In
    /// particular, dangling links and inaccessible parents must fail closed.
    private static func isDefinitelyMissing(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0, errno == ENOENT else { return false }
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if lstat(parent.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR,
                      info.st_uid == geteuid() else { return false }
                let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { return false }
                close(descriptor)
                return true
            }
            guard errno == ENOENT else { return false }
            parent.deleteLastPathComponent()
        }
        return false
    }

    public struct UnavailableError: LocalizedError {
        public let role: EngramRuntimeRole

        public init(role: EngramRuntimeRole) { self.role = role }

        public var errorDescription: String? { role.unavailableMessage }
    }
}

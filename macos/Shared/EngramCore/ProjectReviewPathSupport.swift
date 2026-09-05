import Foundation

public struct ProjectReviewSourceRoot: Equatable, Sendable {
    public let id: String
    public let path: String

    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

/// Read-only project-review path rules shared by the writer and MCP targets.
public enum ProjectReviewPathSupport {
    private static let maxClaudeEncodedUnits = 200

    public static func expandHome(_ path: String, homeDirectory: URL) -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return path }
        let home = homeDirectory.path
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return "\(home)/\(path.dropFirst(2))"
        }
        return path
    }

    public static func canonicalEncodingPath(_ path: String) -> String {
        FileSystemPathIdentity.realpathPath(
            URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }

    public static func encodeClaudeCodeProjectDirectory(_ absolutePath: String) -> String {
        let units = absolutePath.utf16.map { unit -> UInt16 in
            let isAlphanumeric = (unit >= 48 && unit <= 57)
                || (unit >= 65 && unit <= 90)
                || (unit >= 97 && unit <= 122)
            return isAlphanumeric ? unit : 45
        }
        if units.count > maxClaudeEncodedUnits {
            let prefix = Array(units.prefix(maxClaudeEncodedUnits))
            return String(utf16CodeUnits: prefix, count: prefix.count)
                + "-" + claudeHashSuffix(absolutePath)
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    public static func sourceRoots(homeDirectory: URL) -> [ProjectReviewSourceRoot] {
        let catalog = SessionStorageRootCatalog.paths(homeDirectory: homeDirectory)
        let defaultClaudeRoot = catalog.first { $0.id == "claude-code" }?.path
        let resolution = ClaudeCodeProfileResolver(
            homeDirectory: homeDirectory,
            settingsURL: homeDirectory.appendingPathComponent(".engram/settings.json")
        ).resolve()
        let profiles = resolution.profiles.sorted { lhs, rhs in
            if lhs.origin == .default, rhs.origin != .default { return true }
            if lhs.origin != .default, rhs.origin == .default { return false }
            return lhs.projectsRoot < rhs.projectsRoot
        }
        let claudeRoots = profiles.isEmpty
            ? defaultClaudeRoot.map { [$0] } ?? []
            : profiles.map(\.projectsRoot)

        var roots: [ProjectReviewSourceRoot] = []
        for entry in catalog {
            if entry.id == "claude-code" {
                roots.append(contentsOf: claudeRoots.map {
                    ProjectReviewSourceRoot(id: entry.id, path: $0)
                })
            } else {
                roots.append(ProjectReviewSourceRoot(id: entry.id, path: entry.path))
            }
        }
        return roots
    }

    private static func claudeHashSuffix(_ absolutePath: String) -> String {
        var hash: Int32 = 0
        for unit in absolutePath.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        let value = Int64(hash)
        let magnitude = UInt64(value < 0 ? -value : value)
        return base36(magnitude)
    }

    private static func base36(_ value: UInt64) -> String {
        if value == 0 { return "0" }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var remaining = value
        var output = ""
        while remaining > 0 {
            output.insert(alphabet[Int(remaining % 36)], at: output.startIndex)
            remaining /= 36
        }
        return output
    }
}

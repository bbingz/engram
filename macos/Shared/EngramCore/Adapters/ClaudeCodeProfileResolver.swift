import CryptoKit
import Foundation

public struct ClaudeCodeProfile: Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case `default`, automatic, custom
    }

    public let id: String
    public let displayName: String
    public let projectsRoot: String
    public let origin: Origin
    public let available: Bool
    public let sourceReclamationAllowed: Bool

    public init(
        id: String,
        displayName: String,
        projectsRoot: String,
        origin: Origin,
        available: Bool,
        sourceReclamationAllowed: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.projectsRoot = projectsRoot
        self.origin = origin
        self.available = available
        self.sourceReclamationAllowed = sourceReclamationAllowed
    }
}

public struct ClaudeCodeProfileSettings: Equatable, Sendable {
    public let autoDiscover: Bool
    public let customProjectsRoots: [String]

    public init(autoDiscover: Bool, customProjectsRoots: [String]) {
        self.autoDiscover = autoDiscover
        self.customProjectsRoots = customProjectsRoots
    }
}

public struct ClaudeCodeProfileResolution: Equatable, Sendable {
    public let settings: ClaudeCodeProfileSettings
    public let profiles: [ClaudeCodeProfile]
    public let configurationError: String?

    public init(
        settings: ClaudeCodeProfileSettings,
        profiles: [ClaudeCodeProfile],
        configurationError: String?
    ) {
        self.settings = settings
        self.profiles = profiles
        self.configurationError = configurationError
    }
}

public struct ClaudeCodeProfileResolver: Sendable {
    private enum ValidationError: Error {
        case invalidSettings
        case invalidRoot
    }

    private struct RootCandidate {
        let url: URL
        let displayName: String
        let origin: ClaudeCodeProfile.Origin
    }

    private static let maximumCustomRoots = 64
    private static let maximumPathBytes = 4_096
    private static let maximumSettingsBytes = 256 * 1_024
    private static let configurationError = "invalid_claude_code_profiles"
    private static let defaultSettings = ClaudeCodeProfileSettings(
        autoDiscover: true,
        customProjectsRoots: []
    )

    private let homeDirectory: URL
    private let settingsURL: URL

    public init(homeDirectory: URL, settingsURL: URL) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.settingsURL = settingsURL.standardizedFileURL
    }

    public func resolve() -> ClaudeCodeProfileResolution {
        let settingsResult = loadSettings()
        let settings: ClaudeCodeProfileSettings
        let configurationError: String?
        switch settingsResult {
        case .success(let loaded):
            settings = loaded
            configurationError = nil
        case .failure:
            settings = Self.defaultSettings
            configurationError = Self.configurationError
        }

        return ClaudeCodeProfileResolution(
            settings: settings,
            profiles: profiles(for: settings),
            configurationError: configurationError
        )
    }

    public func validateCustomProjectsRoots(_ roots: [String]) throws -> [String] {
        try validatedRoots(roots, requireAvailable: true)
    }

    private func loadSettings() -> Result<ClaudeCodeProfileSettings, ValidationError> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return .success(Self.defaultSettings)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: settingsURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size <= Int64(Self.maximumSettingsBytes),
              let data = boundedSettingsData(),
              let topLevel = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.invalidSettings)
        }

        guard let rawProfiles = topLevel["claudeCodeProfiles"] else {
            return .success(Self.defaultSettings)
        }
        guard let object = rawProfiles as? [String: Any],
              let autoDiscover = strictJSONBoolean(object["autoDiscover"]),
              let roots = object["customProjectsRoots"] as? [String],
              object.count == 2,
              let validated = try? validatedRoots(roots, requireAvailable: false)
        else {
            return .failure(.invalidSettings)
        }

        return .success(
            ClaudeCodeProfileSettings(
                autoDiscover: autoDiscover,
                customProjectsRoots: validated
            )
        )
    }

    private func boundedSettingsData() -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: settingsURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumSettingsBytes + 1),
              data.count <= Self.maximumSettingsBytes
        else {
            return nil
        }
        return data
    }

    private func profiles(for settings: ClaudeCodeProfileSettings) -> [ClaudeCodeProfile] {
        var candidates: [RootCandidate] = []
        let defaultRoot = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        if isDirectory(defaultRoot) {
            candidates.append(
                RootCandidate(url: defaultRoot, displayName: "Default", origin: .default)
            )
        }

        if settings.autoDiscover {
            candidates.append(contentsOf: automaticCandidates())
        }

        candidates.append(contentsOf: settings.customProjectsRoots.map { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return RootCandidate(
                url: url,
                displayName: url.deletingLastPathComponent().lastPathComponent,
                origin: .custom
            )
        })

        var profilesByRoot: [String: ClaudeCodeProfile] = [:]
        for candidate in candidates {
            let canonicalURL = canonicalURL(candidate.url)
            let canonicalPath = canonicalURL.path
            guard profilesByRoot[canonicalPath] == nil else { continue }
            profilesByRoot[canonicalPath] = ClaudeCodeProfile(
                id: profileID(origin: candidate.origin, canonicalPath: canonicalPath),
                displayName: candidate.displayName,
                projectsRoot: canonicalPath,
                origin: candidate.origin,
                available: isAvailableDirectory(canonicalURL),
                sourceReclamationAllowed: sourceReclamationAllowed(
                    for: candidate,
                    canonicalRoot: canonicalURL
                )
            )
        }

        return profilesByRoot.values.sorted { $0.projectsRoot < $1.projectsRoot }
    }

    private func sourceReclamationAllowed(
        for candidate: RootCandidate,
        canonicalRoot: URL
    ) -> Bool {
        let expectedParentName: String
        switch candidate.origin {
        case .default:
            expectedParentName = ".claude"
        case .automatic:
            expectedParentName = candidate.url.deletingLastPathComponent().lastPathComponent
            guard expectedParentName.hasPrefix(".claude-") else { return false }
        case .custom:
            return false
        }

        let canonicalHome = canonicalURL(homeDirectory)
        let declaredParent = candidate.url.deletingLastPathComponent()
        let canonicalParent = canonicalURL(declaredParent)
        let expectedParent = canonicalHome
            .appendingPathComponent(expectedParentName, isDirectory: true)
            .standardizedFileURL
        let expectedRoot = expectedParent
            .appendingPathComponent("projects", isDirectory: true)
            .standardizedFileURL

        return declaredParent.lastPathComponent == expectedParentName
            && canonicalParent.path == expectedParent.path
            && canonicalRoot.path == expectedRoot.path
    }

    private func automaticCandidates() -> [RootCandidate] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return children.compactMap { child in
            let name = child.lastPathComponent
            guard name.hasPrefix(".claude-") else { return nil }
            let projectsRoot = child.appendingPathComponent("projects", isDirectory: true)
            guard isDirectory(projectsRoot) else { return nil }
            let suffix = String(name.dropFirst(".claude-".count))
            return RootCandidate(
                url: projectsRoot,
                displayName: suffix.isEmpty ? name : suffix,
                origin: .automatic
            )
        }.sorted { $0.url.path < $1.url.path }
    }

    private func validatedRoots(_ roots: [String], requireAvailable: Bool) throws -> [String] {
        guard roots.count <= Self.maximumCustomRoots else {
            throw ValidationError.invalidRoot
        }

        let canonicalHome = canonicalURL(homeDirectory)
        let engramRoot = canonicalURL(
            homeDirectory.appendingPathComponent(".engram", isDirectory: true)
        )
        let archiveRoot = canonicalURL(
            engramRoot.appendingPathComponent("archive-v2", isDirectory: true)
        )
        var seen = Set<String>()
        var validated: [String] = []

        for path in roots {
            guard path.utf8.count <= Self.maximumPathBytes,
                  path.hasPrefix("/"),
                  !path.isEmpty
            else {
                throw ValidationError.invalidRoot
            }

            let declaredURL = URL(fileURLWithPath: path, isDirectory: true)
            let standardizedURL = declaredURL.standardizedFileURL
            guard standardizedURL.path == path,
                  standardizedURL.lastPathComponent == "projects"
            else {
                throw ValidationError.invalidRoot
            }

            let canonical = canonicalURL(standardizedURL)
            let canonicalPath = canonical.path
            guard canonical.lastPathComponent == "projects",
                  canonicalPath != "/",
                  canonicalPath != canonicalHome.path,
                  canonicalPath != engramRoot.path,
                  !isSameOrDescendant(canonicalPath, of: archiveRoot.path),
                  seen.insert(canonicalPath).inserted,
                  !requireAvailable || isAvailableDirectory(canonical)
            else {
                throw ValidationError.invalidRoot
            }
            validated.append(canonicalPath)
        }

        return validated.sorted()
    }

    private func strictJSONBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isAvailableDirectory(_ url: URL) -> Bool {
        isDirectory(url) && FileManager.default.isReadableFile(atPath: url.path)
    }

    private func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func profileID(
        origin: ClaudeCodeProfile.Origin,
        canonicalPath: String
    ) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(origin.rawValue)-\(digest)"
    }
}

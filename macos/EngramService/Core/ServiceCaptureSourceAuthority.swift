import CoreFoundation
import Darwin
import Foundation
import EngramCoreRead
import EngramCoreWrite

public enum ServiceCaptureSourceAuthorityError: Error, Equatable, Sendable {
    case invalidFile
    case invalidDocument
    case capturePolicyUnavailable
    case sourceDisabled
}

public struct ServiceCaptureSourceAuthorityEntry: Equatable, Sendable {
    public let machineID: String
    public let sourceInstanceID: String
    public let source: SourceName
    public let parseFormat: CaptureIngestParseFormat
    public let configuredRoot: String
    public let initialEpoch: String
}

/// Explicit HQ source-authority file. This never approves a later epoch and
/// never treats an accepted publication as registration.
public enum ServiceCaptureSourceAuthority {
    public static let commandName = "captureIngestSourceAuthority"
    public static let maximumBytes = 256 * 1024
    private static let exactRootKeys: Set<String> = ["schemaVersion", "sources"]
    private static let exactSourceKeys: Set<String> = [
        "machineID", "sourceInstanceID", "source", "parseFormat", "configuredRoot", "initialEpoch",
    ]

    public static func load(url: URL) throws -> [ServiceCaptureSourceAuthorityEntry] {
        let bytes = try readOwnerFile(url)
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ServiceCaptureSourceAuthorityError.invalidDocument
        }
        guard Set(root.keys) == exactRootKeys, exactInteger(root["schemaVersion"], expected: 1),
              let sources = root["sources"] as? [[String: Any]], (1...64).contains(sources.count) else {
            throw ServiceCaptureSourceAuthorityError.invalidDocument
        }
        return try sources.map(decodeSource)
    }

    public static func provision(
        entries: [ServiceCaptureSourceAuthorityEntry],
        gate: ServiceWriterGate,
        settingsURL: URL
    ) async throws {
        guard (1...64).contains(entries.count) else {
            throw ServiceCaptureSourceAuthorityError.invalidDocument
        }
        _ = try requireIndexCaptureAdmission(at: settingsURL)
        _ = try await gate.performWriteCommand(name: commandName) { writer in
            try writer.write { db in
                let policy = try requireIndexCaptureAdmission(at: settingsURL)
                for entry in entries {
                    guard policy.enabledSources.contains(entry.source) else {
                        throw ServiceCaptureSourceAuthorityError.sourceDisabled
                    }
                    _ = try CaptureIngestSourceRegistry.provision(
                        db, machineID: entry.machineID, sourceInstanceID: entry.sourceInstanceID,
                        source: entry.source, parseFormat: entry.parseFormat,
                        configuredRoot: entry.configuredRoot, initialEpoch: entry.initialEpoch
                    )
                }
            }
        }
    }

    private static func decodeSource(_ raw: [String: Any]) throws -> ServiceCaptureSourceAuthorityEntry {
        guard Set(raw.keys) == exactSourceKeys,
              let machineID = raw["machineID"] as? String, isCanonicalUUID(machineID),
              let sourceInstanceID = raw["sourceInstanceID"] as? String, isCanonicalUUID(sourceInstanceID),
              let sourceName = raw["source"] as? String, let source = SourceName(rawValue: sourceName),
              let formatName = raw["parseFormat"] as? String,
              let parseFormat = CaptureIngestParseFormat(rawValue: formatName),
              isCompatible(source: source, parseFormat: parseFormat),
              let configuredRoot = raw["configuredRoot"] as? String, isCanonicalAbsolutePath(configuredRoot),
              let initialEpoch = raw["initialEpoch"] as? String, isCanonicalUUID(initialEpoch) else {
            throw ServiceCaptureSourceAuthorityError.invalidDocument
        }
        return ServiceCaptureSourceAuthorityEntry(
            machineID: machineID, sourceInstanceID: sourceInstanceID, source: source,
            parseFormat: parseFormat, configuredRoot: configuredRoot, initialEpoch: initialEpoch
        )
    }

    /// Index-only gate, then the same enabled capture policy intake uses.
    /// `ServiceCaptureIngestRuntime.policy` also admits `local`; this path does not.
    private static func requireIndexCaptureAdmission(
        at settingsURL: URL
    ) throws -> ServiceCaptureIngestParserPolicy {
        guard let root = settingsRoot(at: settingsURL) else {
            throw ServiceCaptureSourceAuthorityError.capturePolicyUnavailable
        }
        guard isExplicitIndexRole(root) else {
            throw ServiceCaptureSourceAuthorityError.capturePolicyUnavailable
        }
        guard let policy = capturePolicy(from: root) else {
            throw ServiceCaptureSourceAuthorityError.capturePolicyUnavailable
        }
        return policy
    }

    private static func isExplicitIndexRole(_ root: [String: Any]) -> Bool {
        guard let role = root["runtimeRole"] as? String else { return false }
        return role == "index"
    }

    private static func settingsRoot(at settingsURL: URL) -> [String: Any]? {
        guard let bytes = SecureRegularFile.read(
            atPath: settingsURL.path, maximumBytes: RuntimeRoleSettings.maximumBytes, repairPermissions: false
        ), let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return root
    }

    /// Mirrors HQ intake policy (`local` or `index`, or omitted role). Callers
    /// that must stay index-only check `isExplicitIndexRole` separately.
    private static func capturePolicy(from root: [String: Any]) -> ServiceCaptureIngestParserPolicy? {
        guard let configuration = try? ServiceCaptureIngestConfiguration.decode(settings: root),
              ["hq", "m1"].contains(configuration.credentialID) else { return nil }
        if let value = root["runtimeRole"] {
            guard let role = value as? String, role == "local" || role == "index" else { return nil }
        }
        let migrated: Bool
        if let value = root[ArchivedDefaultOffSources.settingsMigrationKey] {
            guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else { return nil }
            migrated = flag
        } else { migrated = false }
        var disabled = ArchivedDefaultOffSources.ids
        if let value = root["disabledSources"] {
            guard let sources = value as? [String] else { return nil }
            disabled = Set(sources)
            if !migrated { disabled.formUnion(ArchivedDefaultOffSources.ids) }
        }
        return ServiceCaptureIngestParserPolicy(
            parserRevision: "swift-capture-v1",
            enabledSources: Set(SourceName.allCases.filter { !disabled.contains($0.rawValue) })
        )
    }

    private static func readOwnerFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ServiceCaptureSourceAuthorityError.invalidFile }
        let path = url.path
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), let name = components.last, name != ".", name != ".." else {
            throw ServiceCaptureSourceAuthorityError.invalidFile
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ServiceCaptureSourceAuthorityError.invalidFile }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ServiceCaptureSourceAuthorityError.invalidFile }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ServiceCaptureSourceAuthorityError.invalidFile }
        defer { close(descriptor) }
        var before = stat()
        var named = stat()
        guard fstat(descriptor, &before) == 0,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino,
              before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
              before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw ServiceCaptureSourceAuthorityError.invalidFile
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, maximumBytes + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ServiceCaptureSourceAuthorityError.invalidFile
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var namedAfter = stat()
        guard data.count <= maximumBytes, data.count == before.st_size, fstat(descriptor, &after) == 0,
              fstatat(directory, name, &namedAfter, AT_SYMLINK_NOFOLLOW) == 0,
              namedAfter.st_dev == after.st_dev, namedAfter.st_ino == after.st_ino,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid,
              before.st_nlink == after.st_nlink, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ServiceCaptureSourceAuthorityError.invalidFile
        }
        return data
    }

    private static func exactInteger(_ value: Any?, expected: Int) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              Int(exactly: number.doubleValue) == expected else { return false }
        return true
    }

    private static func isCompatible(source: SourceName, parseFormat: CaptureIngestParseFormat) -> Bool {
        switch parseFormat {
        case .claudeDefault:
            return source == .claudeCode || source == .minimax || source == .lobsterai
        case .claudeCustomProfile:
            return source == .claudeCode
        case .codex:
            return source == .codex
        case .qwen:
            return source == .qwen
        case .cline:
            return source == .cline
        case .iflow:
            return source == .iflow
        case .qoder:
            return source == .qoder
        case .commandcode:
            return source == .commandcode
        case .copilot:
            return source == .copilot
        case .geminiCli:
            return source == .geminiCli
        case .opencode:
            return source == .opencode
        case .kimi:
            return source == .kimi
        case .cursor:
            return source == .cursor
        case .vscode:
            return source == .vscode
        case .antigravityCLITranscript:
            return source == .antigravity
        case .windsurfHookTranscript:
            return source == .windsurf
        case .pi:
            return source == .pi
        case .grok:
            return source == .grok
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let canonical = UUID(uuidString: value)?.uuidString else { return false }
        return canonical.utf8.elementsEqual(value.utf8)
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count > 1, bytes.first == 47, !bytes.contains(0) else { return false }
        return bytes.dropFirst().split(separator: 47, omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.elementsEqual([46]) && !$0.elementsEqual([46, 46])
        }
    }
}

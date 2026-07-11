import CoreFoundation
import EngramCoreWrite
import Foundation

public enum ArchiveV2SettingsConfigurationError: String, Error, Equatable, Sendable {
    case invalidSettingsJSON = "invalid_settings_json"
    case invalidExactArchiveFlag = "invalid_exact_archive_flag"
    case invalidRemoteConfiguration = "invalid_remote_configuration"
    case invalidBatchSize = "invalid_batch_size"
    case invalidReplicaSet = "invalid_replica_set"
    case invalidReplicaOrigin = "invalid_replica_origin"
    case duplicateReplicaOrigin = "duplicate_replica_origin"
    case invalidExcludedProjectRoot = "invalid_excluded_project_root"
}

public struct ArchiveV2RemoteConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let batchSize: Int
    public let replicas: [ArchiveReplicaDescriptor]
    public let excludedProjectRoots: [String]

    public init(
        enabled: Bool,
        batchSize: Int,
        replicas: [ArchiveReplicaDescriptor],
        excludedProjectRoots: [String]
    ) {
        self.enabled = enabled
        self.batchSize = batchSize
        self.replicas = replicas
        self.excludedProjectRoots = excludedProjectRoots
    }
}

public struct ArchiveV2Settings: Equatable, Sendable {
    public static let defaultBatchSize = 20
    public static let batchSizeRange = 1 ... 100

    public let exactArchiveEnabled: Bool
    public let remoteConfiguration: ArchiveV2RemoteConfiguration?
    public let configurationError: ArchiveV2SettingsConfigurationError?

    public var remoteReplicationEnabled: Bool {
        exactArchiveEnabled && remoteConfiguration?.enabled == true
    }

    public static func load(
        settingsURL: URL,
        environment: [String: String]
    ) -> ArchiveV2Settings {
        let settingsFile = readSettingsFile(at: settingsURL)

        let exactResult = resolveExactArchiveEnabled(
            settingsFile: settingsFile,
            environment: environment
        )
        guard case .success(let exactEnabled) = exactResult else {
            return failed(
                exactArchiveEnabled: false,
                error: exactResult.error ?? .invalidExactArchiveFlag
            )
        }

        let remoteObjectResult = resolveRemoteObject(
            settingsFile: settingsFile,
            environment: environment
        )
        guard case .success(let remoteObject) = remoteObjectResult else {
            return failed(
                exactArchiveEnabled: exactEnabled,
                error: remoteObjectResult.error ?? .invalidRemoteConfiguration
            )
        }
        guard let remoteObject else {
            return ArchiveV2Settings(
                exactArchiveEnabled: exactEnabled,
                remoteConfiguration: nil,
                configurationError: nil
            )
        }

        switch parseRemoteConfiguration(remoteObject) {
        case .success(let remote):
            return ArchiveV2Settings(
                exactArchiveEnabled: exactEnabled,
                remoteConfiguration: remote,
                configurationError: nil
            )
        case .failure(let error):
            return failed(exactArchiveEnabled: exactEnabled, error: error)
        }
    }

    public func isProjectExcluded(_ projectRoot: String) -> Bool {
        guard let normalized = Self.strictNormalizedAbsolutePath(projectRoot) else {
            return false
        }
        return remoteConfiguration?.excludedProjectRoots.contains { excludedRoot in
            normalized == excludedRoot || normalized.hasPrefix(excludedRoot + "/")
        } ?? false
    }

    private enum SettingsFile {
        case missing
        case object([String: Any])
        case invalid
    }

    private enum Resolution<Value> {
        case success(Value)
        case failure(ArchiveV2SettingsConfigurationError)

        var error: ArchiveV2SettingsConfigurationError? {
            guard case .failure(let error) = self else { return nil }
            return error
        }
    }

    private static func failed(
        exactArchiveEnabled: Bool,
        error: ArchiveV2SettingsConfigurationError
    ) -> ArchiveV2Settings {
        ArchiveV2Settings(
            exactArchiveEnabled: exactArchiveEnabled,
            remoteConfiguration: nil,
            configurationError: error
        )
    }

    private static func readSettingsFile(at settingsURL: URL) -> SettingsFile {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .invalid
        }
        return .object(object)
    }

    private static func resolveExactArchiveEnabled(
        settingsFile: SettingsFile,
        environment: [String: String]
    ) -> Resolution<Bool> {
        if let override = environment["ENGRAM_EXACT_ARCHIVE_ENABLED"] {
            guard let value = strictBoolean(override) else {
                return .failure(.invalidExactArchiveFlag)
            }
            return .success(value)
        }

        switch settingsFile {
        case .missing:
            return .success(false)
        case .invalid:
            return .failure(.invalidSettingsJSON)
        case .object(let object):
            guard let rawValue = object["exactArchiveEnabled"] else {
                return .success(false)
            }
            guard let value = strictJSONBoolean(rawValue) else {
                return .failure(.invalidExactArchiveFlag)
            }
            return .success(value)
        }
    }

    private static func resolveRemoteObject(
        settingsFile: SettingsFile,
        environment: [String: String]
    ) -> Resolution<[String: Any]?> {
        if let override = environment["ENGRAM_REMOTE_ARCHIVE_V2_CONFIG_JSON"] {
            guard let data = override.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .failure(.invalidRemoteConfiguration)
            }
            return .success(object)
        }

        switch settingsFile {
        case .missing:
            return .success(nil)
        case .invalid:
            return .failure(.invalidSettingsJSON)
        case .object(let object):
            guard let rawRemote = object["remoteArchiveV2"] else {
                return .success(nil)
            }
            guard let remote = rawRemote as? [String: Any] else {
                return .failure(.invalidRemoteConfiguration)
            }
            return .success(remote)
        }
    }

    private static func parseRemoteConfiguration(
        _ object: [String: Any]
    ) -> Resolution<ArchiveV2RemoteConfiguration> {
        let allowedRemoteKeys: Set<String> = [
            "enabled",
            "batchSize",
            "replicas",
            "excludedProjectRoots",
        ]
        guard Set(object.keys).isSubset(of: allowedRemoteKeys) else {
            return .failure(.invalidRemoteConfiguration)
        }
        let allowedReplicaKeys: Set<String> = ["id", "serverURL", "requireTLS"]
        let replicaObjects: [[String: Any]]?
        if let rawReplicas = object["replicas"] {
            guard let values = rawReplicas as? [Any] else {
                return .failure(.invalidReplicaSet)
            }
            var parsed: [[String: Any]] = []
            for value in values {
                guard let replica = value as? [String: Any],
                      Set(replica.keys).isSubset(of: allowedReplicaKeys) else {
                    return .failure(.invalidReplicaSet)
                }
                parsed.append(replica)
            }
            replicaObjects = parsed
        } else {
            replicaObjects = nil
        }
        guard let enabled = strictJSONBoolean(object["enabled"]) else {
            return .failure(.invalidRemoteConfiguration)
        }

        let batchSize: Int
        if let rawBatchSize = object["batchSize"] {
            guard let parsed = strictJSONInteger(rawBatchSize),
                  batchSizeRange.contains(parsed) else {
                return .failure(.invalidBatchSize)
            }
            batchSize = parsed
        } else {
            batchSize = defaultBatchSize
        }

        let excludedRootsResult = parseExcludedRoots(object["excludedProjectRoots"])
        guard case .success(let excludedRoots) = excludedRootsResult else {
            return .failure(excludedRootsResult.error ?? .invalidExcludedProjectRoot)
        }

        guard enabled else {
            return .success(
                ArchiveV2RemoteConfiguration(
                    enabled: false,
                    batchSize: batchSize,
                    replicas: [],
                    excludedProjectRoots: excludedRoots
                )
            )
        }

        guard let replicaObjects, replicaObjects.count == 2 else {
            return .failure(.invalidReplicaSet)
        }
        var resolved: [(descriptor: ArchiveReplicaDescriptor, canonicalOrigin: String)] = []
        for replica in replicaObjects {
            guard let id = replica["id"] as? String,
                  let serverURL = replica["serverURL"] as? String,
                  let requireTLS = strictJSONBoolean(replica["requireTLS"])
            else {
                return .failure(.invalidReplicaSet)
            }
            let canonicalOrigin: URL
            do {
                canonicalOrigin = try ArchiveReplicaOrigin.canonicalURL(
                    serverURL,
                    requireTLS: requireTLS
                )
            } catch {
                return .failure(.invalidReplicaOrigin)
            }
            resolved.append(
                (
                    ArchiveReplicaDescriptor(
                        id: id,
                        serverURL: canonicalOrigin.absoluteString,
                        requireTLS: requireTLS
                    ),
                    canonicalOrigin.absoluteString
                )
            )
        }

        guard Set(resolved.map { $0.descriptor.id }) == Set(["hq", "m1"]) else {
            return .failure(.invalidReplicaSet)
        }
        guard Set(resolved.map { $0.canonicalOrigin }).count == 2 else {
            return .failure(.duplicateReplicaOrigin)
        }
        return .success(
            ArchiveV2RemoteConfiguration(
                enabled: true,
                batchSize: batchSize,
                replicas: resolved.map { $0.descriptor }.sorted { $0.id < $1.id },
                excludedProjectRoots: excludedRoots
            )
        )
    }

    private static func parseExcludedRoots(
        _ rawValue: Any?
    ) -> Resolution<[String]> {
        guard let rawValue else { return .success([]) }
        guard let values = rawValue as? [Any] else {
            return .failure(.invalidExcludedProjectRoot)
        }
        var roots: [String] = []
        var seen = Set<String>()
        for value in values {
            guard let path = value as? String,
                  let normalized = strictNormalizedAbsolutePath(path) else {
                return .failure(.invalidExcludedProjectRoot)
            }
            if seen.insert(normalized).inserted {
                roots.append(normalized)
            }
        }
        return .success(roots)
    }

    private static func strictNormalizedAbsolutePath(_ value: String) -> String? {
        guard !value.isEmpty,
              value != "/",
              value.hasPrefix("/"),
              !value.utf8.contains(0)
        else {
            return nil
        }
        let normalized = URL(fileURLWithPath: value).standardizedFileURL.path
        guard normalized == value else { return nil }
        return normalized
    }

    private static func strictBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private static func strictJSONBoolean(_ value: Any?) -> Bool? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
            return nil
        }
        return value as? Bool
    }

    private static func strictJSONInteger(_ value: Any) -> Int? {
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else {
            return nil
        }
        return value as? Int
    }
}

import Foundation
import CoreFoundation
import Darwin
import EngramCoreRead

public enum ServiceCaptureIngestConfigurationError: Error, Equatable, Sendable {
    case invalidSettings
    case invalidConfiguration
}

/// Explicit intake settings only. Credentials and source admission remain external.
public struct ServiceCaptureIngestConfiguration: Equatable, Sendable {
    public let serverID: String
    public let baseURL: URL
    public let credentialID: String
    public let pageLimit: Int
    public let maxPages: Int
    public let maxRunBytes: Int
    public let requestTimeout: TimeInterval
    public let retryCount: Int

    public init(serverID: String, baseURL: URL, credentialID: String,
                pageLimit: Int = 10, maxPages: Int = 2, maxRunBytes: Int = 32 * 1024 * 1024,
                requestTimeout: TimeInterval = 15, retryCount: Int = 1) throws {
        guard Self.identifier(serverID), Self.identifier(credentialID),
              (1...CollectorPublicationProtocolLimits.maxPageItems).contains(pageLimit),
              (1...10).contains(maxPages), (1024...128 * 1024 * 1024).contains(maxRunBytes),
              requestTimeout.isFinite, (0.1...60).contains(requestTimeout),
              (0...3).contains(retryCount),
              let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              baseURL.absoluteString.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              !baseURL.absoluteString.contains("%"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme == "https" || (parts.scheme == "http" && (host == "127.0.0.1" || host == "[::1]"))
        else { throw ServiceCaptureIngestConfigurationError.invalidConfiguration }
        self.serverID = serverID
        self.baseURL = baseURL
        self.credentialID = credentialID
        self.pageLimit = pageLimit
        self.maxPages = maxPages
        self.maxRunBytes = maxRunBytes
        self.requestTimeout = requestTimeout
        self.retryCount = retryCount
    }

    public static func load(at settingsURL: URL) throws -> Self? {
        guard let bytes = SecureRegularFile.read(atPath: settingsURL.path,
            maximumBytes: RuntimeRoleSettings.maximumBytes, repairPermissions: false) else {
            var info = stat()
            // Missing is OFF; links, unsafe permissions, unreadable files and
            // all other failed reads never authorize intake.
            if lstat(settingsURL.path, &info) != 0, errno == ENOENT { return nil }
            throw ServiceCaptureIngestConfigurationError.invalidSettings
        }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ServiceCaptureIngestConfigurationError.invalidSettings
        }
        return try decode(settings: root)
    }

    /// Allows the runtime to authorize role, sources and intake from one secure
    /// settings snapshot without a second file read or permission repair.
    static func decode(settings root: [String: Any]) throws -> Self? {
        guard let raw = root["captureIngest"] else { return nil }
        guard let block = raw as? [String: Any],
              Set(block.keys).isSubset(of: ["enabled", "serverID", "baseURL", "credentialID",
                  "pageLimit", "maxPages", "maxRunBytes", "requestTimeout", "retryCount"]),
              let flag = block["enabled"], CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID(),
              let enabled = flag as? Bool else {
            throw ServiceCaptureIngestConfigurationError.invalidConfiguration
        }
        if !enabled {
            guard block.count == 1 else { throw ServiceCaptureIngestConfigurationError.invalidConfiguration }
            return nil
        }
        guard let serverID = block["serverID"] as? String,
              let origin = block["baseURL"] as? String, let url = URL(string: origin),
              let credentialID = block["credentialID"] as? String else {
            throw ServiceCaptureIngestConfigurationError.invalidConfiguration
        }
        func integer(_ key: String, default fallback: Int) throws -> Int {
            guard let value = block[key] else { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  let result = Int(exactly: number.doubleValue) else {
                throw ServiceCaptureIngestConfigurationError.invalidConfiguration
            }
            return result
        }
        let timeout: TimeInterval
        if let value = block["requestTimeout"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw ServiceCaptureIngestConfigurationError.invalidConfiguration
            }
            timeout = number.doubleValue
        } else { timeout = 15 }
        return try Self(serverID: serverID, baseURL: url, credentialID: credentialID,
            pageLimit: integer("pageLimit", default: 10), maxPages: integer("maxPages", default: 2),
            maxRunBytes: integer("maxRunBytes", default: 32 * 1024 * 1024), requestTimeout: timeout,
            retryCount: integer("retryCount", default: 1))
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }
}

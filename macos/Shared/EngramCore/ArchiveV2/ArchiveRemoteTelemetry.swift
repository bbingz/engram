import Foundation

public struct ArchiveRemoteTelemetryEndpoint: Codable, Equatable, Sendable {
    public let endpoint: String
    public let requestCount: Int64
    public let errorCount: Int64
    public let totalDurationMs: Double
    public let maximumDurationMs: Double
    public let requestBytes: Int64
    public let responseBytes: Int64

    public init(
        endpoint: String,
        requestCount: Int64,
        errorCount: Int64,
        totalDurationMs: Double,
        maximumDurationMs: Double,
        requestBytes: Int64,
        responseBytes: Int64
    ) throws {
        guard ArchiveRemoteTelemetryValidation.endpoints.contains(endpoint) else {
            throw ArchiveV2ValidationError.invalidValue(field: "endpoint")
        }
        guard requestCount >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "requestCount")
        }
        guard errorCount >= 0, errorCount <= requestCount else {
            throw ArchiveV2ValidationError.invalidValue(field: "errorCount")
        }
        guard totalDurationMs.isFinite, totalDurationMs >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "totalDurationMs")
        }
        guard maximumDurationMs.isFinite,
              maximumDurationMs >= 0,
              maximumDurationMs <= totalDurationMs else {
            throw ArchiveV2ValidationError.invalidValue(field: "maximumDurationMs")
        }
        guard requestBytes >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "requestBytes")
        }
        guard responseBytes >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "responseBytes")
        }

        self.endpoint = endpoint
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.totalDurationMs = totalDurationMs
        self.maximumDurationMs = maximumDurationMs
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            endpoint: container.decode(String.self, forKey: .endpoint),
            requestCount: container.decode(Int64.self, forKey: .requestCount),
            errorCount: container.decode(Int64.self, forKey: .errorCount),
            totalDurationMs: container.decode(Double.self, forKey: .totalDurationMs),
            maximumDurationMs: container.decode(Double.self, forKey: .maximumDurationMs),
            requestBytes: container.decode(Int64.self, forKey: .requestBytes),
            responseBytes: container.decode(Int64.self, forKey: .responseBytes)
        )
    }
}

public struct ArchiveRemoteTelemetryError: Codable, Equatable, Sendable {
    public let timestamp: String
    public let endpoint: String
    public let method: String
    public let statusCode: Int
    public let category: String

    public init(
        timestamp: String,
        endpoint: String,
        method: String,
        statusCode: Int,
        category: String
    ) throws {
        guard ArchiveRemoteTelemetryValidation.isCanonicalTimestamp(timestamp) else {
            throw ArchiveV2ValidationError.invalidValue(field: "timestamp")
        }
        guard ArchiveRemoteTelemetryValidation.endpoints.contains(endpoint) else {
            throw ArchiveV2ValidationError.invalidValue(field: "endpoint")
        }
        guard ArchiveRemoteTelemetryValidation.methods.contains(method) else {
            throw ArchiveV2ValidationError.invalidValue(field: "method")
        }
        guard (400...599).contains(statusCode) else {
            throw ArchiveV2ValidationError.invalidValue(field: "statusCode")
        }
        guard ArchiveRemoteTelemetryValidation.errorCategories.contains(category) else {
            throw ArchiveV2ValidationError.invalidValue(field: "category")
        }

        self.timestamp = timestamp
        self.endpoint = endpoint
        self.method = method
        self.statusCode = statusCode
        self.category = category
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            timestamp: container.decode(String.self, forKey: .timestamp),
            endpoint: container.decode(String.self, forKey: .endpoint),
            method: container.decode(String.self, forKey: .method),
            statusCode: container.decode(Int.self, forKey: .statusCode),
            category: container.decode(String.self, forKey: .category)
        )
    }
}

public struct ArchiveRemoteTelemetrySnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumErrors = 100
    public static let maximumEndpoints = 7
    public static let maximumEncodedBytes = 64 * 1_024

    public let schema: Int
    public let serverID: String
    public let sourceRevision: String
    public let processStartedAt: String
    public let snapshotAt: String
    public let uptimeSeconds: Double
    public let diskAvailableBytes: Int64?
    public let diskTotalBytes: Int64?
    public let requestCount: Int64
    public let successCount: Int64
    public let clientErrorCount: Int64
    public let serverErrorCount: Int64
    public let requestBytes: Int64
    public let responseBytes: Int64
    public let lastArchiveMutationAt: String?
    public let persistenceError: String?
    public let endpoints: [ArchiveRemoteTelemetryEndpoint]
    public let recentErrors: [ArchiveRemoteTelemetryError]

    public init(
        schema: Int = ArchiveRemoteTelemetrySnapshot.schemaVersion,
        serverID: String,
        sourceRevision: String,
        processStartedAt: String,
        snapshotAt: String,
        uptimeSeconds: Double,
        diskAvailableBytes: Int64?,
        diskTotalBytes: Int64?,
        requestCount: Int64,
        successCount: Int64,
        clientErrorCount: Int64,
        serverErrorCount: Int64,
        requestBytes: Int64,
        responseBytes: Int64,
        lastArchiveMutationAt: String?,
        persistenceError: String?,
        endpoints: [ArchiveRemoteTelemetryEndpoint],
        recentErrors: [ArchiveRemoteTelemetryError]
    ) throws {
        guard schema == Self.schemaVersion else {
            throw ArchiveV2ValidationError.unsupportedSchemaVersion(schema)
        }
        guard ArchiveRemoteTelemetryValidation.serverIDs.contains(serverID) else {
            throw ArchiveV2ValidationError.invalidValue(field: "serverID")
        }
        guard ArchiveRemoteTelemetryValidation.isSourceRevision(sourceRevision) else {
            throw ArchiveV2ValidationError.invalidValue(field: "sourceRevision")
        }
        guard ArchiveRemoteTelemetryValidation.isCanonicalTimestamp(processStartedAt) else {
            throw ArchiveV2ValidationError.invalidValue(field: "processStartedAt")
        }
        guard ArchiveRemoteTelemetryValidation.isCanonicalTimestamp(snapshotAt) else {
            throw ArchiveV2ValidationError.invalidValue(field: "snapshotAt")
        }
        guard uptimeSeconds.isFinite, uptimeSeconds >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "uptimeSeconds")
        }
        try Self.validateOptionalCount(diskAvailableBytes, field: "diskAvailableBytes")
        try Self.validateOptionalCount(diskTotalBytes, field: "diskTotalBytes")
        if let diskAvailableBytes, let diskTotalBytes, diskAvailableBytes > diskTotalBytes {
            throw ArchiveV2ValidationError.invalidValue(field: "diskAvailableBytes")
        }
        try Self.validateCount(requestCount, field: "requestCount")
        try Self.validateCount(successCount, field: "successCount")
        try Self.validateCount(clientErrorCount, field: "clientErrorCount")
        try Self.validateCount(serverErrorCount, field: "serverErrorCount")
        try Self.validateCount(requestBytes, field: "requestBytes")
        try Self.validateCount(responseBytes, field: "responseBytes")
        if let lastArchiveMutationAt,
           !ArchiveRemoteTelemetryValidation.isCanonicalTimestamp(lastArchiveMutationAt) {
            throw ArchiveV2ValidationError.invalidValue(field: "lastArchiveMutationAt")
        }
        if let persistenceError,
           !ArchiveRemoteTelemetryValidation.persistenceErrors.contains(persistenceError) {
            throw ArchiveV2ValidationError.invalidValue(field: "persistenceError")
        }
        guard endpoints.count <= Self.maximumEndpoints else {
            throw ArchiveV2ValidationError.invalidValue(field: "endpoints")
        }
        var endpointNames = Set<String>()
        for endpoint in endpoints where !endpointNames.insert(endpoint.endpoint).inserted {
            throw ArchiveV2ValidationError.invalidValue(field: "endpoints")
        }
        guard recentErrors.count <= Self.maximumErrors else {
            throw ArchiveV2ValidationError.invalidValue(field: "recentErrors")
        }

        self.schema = schema
        self.serverID = serverID
        self.sourceRevision = sourceRevision
        self.processStartedAt = processStartedAt
        self.snapshotAt = snapshotAt
        self.uptimeSeconds = uptimeSeconds
        self.diskAvailableBytes = diskAvailableBytes
        self.diskTotalBytes = diskTotalBytes
        self.requestCount = requestCount
        self.successCount = successCount
        self.clientErrorCount = clientErrorCount
        self.serverErrorCount = serverErrorCount
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.lastArchiveMutationAt = lastArchiveMutationAt
        self.persistenceError = persistenceError
        self.endpoints = endpoints
        self.recentErrors = recentErrors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(Int.self, forKey: .schema),
            serverID: container.decode(String.self, forKey: .serverID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            processStartedAt: container.decode(String.self, forKey: .processStartedAt),
            snapshotAt: container.decode(String.self, forKey: .snapshotAt),
            uptimeSeconds: container.decode(Double.self, forKey: .uptimeSeconds),
            diskAvailableBytes: container.decodeIfPresent(Int64.self, forKey: .diskAvailableBytes),
            diskTotalBytes: container.decodeIfPresent(Int64.self, forKey: .diskTotalBytes),
            requestCount: container.decode(Int64.self, forKey: .requestCount),
            successCount: container.decode(Int64.self, forKey: .successCount),
            clientErrorCount: container.decode(Int64.self, forKey: .clientErrorCount),
            serverErrorCount: container.decode(Int64.self, forKey: .serverErrorCount),
            requestBytes: container.decode(Int64.self, forKey: .requestBytes),
            responseBytes: container.decode(Int64.self, forKey: .responseBytes),
            lastArchiveMutationAt: container.decodeIfPresent(
                String.self,
                forKey: .lastArchiveMutationAt
            ),
            persistenceError: container.decodeIfPresent(String.self, forKey: .persistenceError),
            endpoints: container.decode([ArchiveRemoteTelemetryEndpoint].self, forKey: .endpoints),
            recentErrors: container.decode(
                [ArchiveRemoteTelemetryError].self,
                forKey: .recentErrors
            )
        )
    }

    private static func validateCount(_ value: Int64, field: String) throws {
        guard value >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: field)
        }
    }

    private static func validateOptionalCount(_ value: Int64?, field: String) throws {
        guard value == nil || value! >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: field)
        }
    }
}

private enum ArchiveRemoteTelemetryValidation {
    static let serverIDs: Set<String> = ["hq", "m1"]
    static let endpoints: Set<String> = [
        "object", "manifest", "receipt", "machines", "receipts", "status", "unknown",
    ]
    static let methods: Set<String> = ["GET", "HEAD", "PUT", "DELETE"]
    static let persistenceErrors: Set<String> = ["snapshot_write_failed"]
    static let errorCategories: Set<String> = [
        "unauthorized",
        "malformed_request",
        "not_found",
        "conflict",
        "payload_too_large",
        "invalid_content",
        "storage_unavailable",
        "internal_error",
    ]

    static func isSourceRevision(_ value: String) -> Bool {
        value == "unknown"
            || (value.utf8.count == 40 && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
    }

    static func isCanonicalTimestamp(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 24,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              bytes[19] == 46,
              bytes[23] == 90 else {
            return false
        }
        let separators = Set([4, 7, 10, 13, 16, 19, 23])
        guard bytes.indices.allSatisfy({ index in
            separators.contains(index) || (48...57).contains(bytes[index])
        }) else {
            return false
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

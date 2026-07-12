import Foundation
import GRDB
import EngramCoreRead

extension EngramServiceCommandHandler {
    static let archiveReadSessionPageInnerBudget = 160 * 1024

    func archiveReadSessionPageResultData(
        _ request: EngramServiceArchiveReadSessionPageRequest,
        requestId: String
    ) async throws -> Data {
        guard let resolver = archiveTranscriptResolver else {
            throw Self.archiveReadError(
                name: "archiveUnavailable",
                message: "Archived transcript reading is disabled",
                retryPolicy: "safe"
            )
        }

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: writerGate.databasePath,
            configuration: configuration
        )
        guard let session = try TranscriptExportService.fetchSession(
            id: request.sessionId,
            queue: queue
        ) else {
            throw EngramServiceError.invalidRequest(message: "Session not found")
        }

        let transcript: ServiceTranscriptReader.ReadResult
        do {
            let liveURL = session.filePath.isEmpty
                ? nil
                : URL(fileURLWithPath: session.filePath)
            transcript = try await resolver.withResolvedFile(
                sessionID: request.sessionId,
                liveURL: liveURL,
                liveSource: session.source
            ) { selectedURL, selectedSource in
                try await ServiceTranscriptReader.readArchiveMessagesWithMetadata(
                    filePath: selectedURL.path,
                    source: selectedSource
                )
            }.value
        } catch let error as TranscriptSizeGuardError {
            throw ArchiveTranscriptServiceErrorMapper.serviceError(for: error)
        } catch let error as ParserFailure {
            throw ArchiveTranscriptServiceErrorMapper.serviceError(for: error)
        } catch let error as ArchiveTranscriptResolverError {
            throw ArchiveTranscriptServiceErrorMapper.serviceError(for: error)
        } catch is CancellationError {
            throw Self.archiveReadError(
                name: "archiveReadCancelled",
                message: "Archive transcript read was cancelled",
                retryPolicy: "safe"
            )
        }

        let roleFilter = request.roles.map(Set.init)
        let visible = transcript.messages.filter { message in
            roleFilter?.contains(message.role) ?? true
        }
        let totalPages = max(
            1,
            (visible.count + request.pageSize - 1) / request.pageSize
        )
        let start = (request.page - 1) * request.pageSize
        let pageMessages: ArraySlice<ServiceTranscriptMessage>
        if start < visible.count {
            pageMessages = visible[start ..< min(start + request.pageSize, visible.count)]
        } else {
            pageMessages = []
        }
        let messages = pageMessages.map { message in
            EngramServiceArchiveTranscriptMessage(
                role: message.role,
                content: message.content,
                timestamp: Self.boundedTimestamp(message.timestamp)
            )
        }
        let response = try EngramServiceArchiveReadSessionPageResponse(
            messages: messages,
            totalPages: totalPages,
            currentPage: request.page,
            totalKnownComplete: transcript.totalKnownComplete,
            truncatedAt: transcript.truncatedAt,
            responseBudgetTruncated: false
        )
        return try Self.encodeBoundedArchivePage(response, requestId: requestId)
    }

    private static func archiveReadError(
        name: String,
        message: String,
        retryPolicy: String
    ) -> EngramServiceError {
        .commandFailed(
            name: name,
            message: message,
            retryPolicy: retryPolicy,
            details: nil
        )
    }

    private static func boundedTimestamp(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 128,
              !value.utf8.contains(0) else {
            return nil
        }
        return value
    }

    private static func encodeBoundedArchivePage(
        _ response: EngramServiceArchiveReadSessionPageResponse,
        requestId: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        let initial = try encoder.encode(response)
        if archivePageFits(initial, requestId: requestId, encoder: encoder) {
            return initial
        }

        let totalContentBytes = response.messages.reduce(0) { partial, message in
            partial + message.content.utf8.count
        }
        var low = 0
        var high = totalContentBytes
        var best: Data?
        while low <= high {
            let midpoint = low + (high - low) / 2
            let candidate = try responseWithContentBudget(response, byteBudget: midpoint)
            let data = try encoder.encode(candidate)
            if archivePageFits(data, requestId: requestId, encoder: encoder) {
                best = data
                low = midpoint + 1
            } else {
                high = midpoint - 1
            }
        }
        guard let best else {
            throw archiveReadError(
                name: "archiveResponseTooLarge",
                message: "Archive transcript page metadata exceeds the service frame budget",
                retryPolicy: "never"
            )
        }
        return best
    }

    private static func archivePageFits(
        _ data: Data,
        requestId: String,
        encoder: JSONEncoder
    ) -> Bool {
        guard data.count <= archiveReadSessionPageInnerBudget else { return false }
        let envelope = EngramServiceResponseEnvelope.success(
            requestId: requestId,
            result: data
        )
        guard let outer = try? encoder.encode(envelope) else { return false }
        return outer.count < UnixSocketEngramServiceTransport.maximumFrameLength
    }

    private static func responseWithContentBudget(
        _ response: EngramServiceArchiveReadSessionPageResponse,
        byteBudget: Int
    ) throws -> EngramServiceArchiveReadSessionPageResponse {
        var remaining = max(byteBudget, 0)
        let messages = response.messages.map { message in
            let content = utf8Prefix(message.content, maximumBytes: remaining)
            remaining -= content.utf8.count
            return EngramServiceArchiveTranscriptMessage(
                role: message.role,
                content: content,
                timestamp: message.timestamp
            )
        }
        return try EngramServiceArchiveReadSessionPageResponse(
            messages: messages,
            totalPages: response.totalPages,
            currentPage: response.currentPage,
            totalKnownComplete: response.totalKnownComplete,
            truncatedAt: response.truncatedAt,
            responseBudgetTruncated: true
        )
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var used = 0
        for scalar in value.unicodeScalars {
            let width = scalar.utf8.count
            guard used + width <= maximumBytes else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        return result
    }
}

enum ArchiveTranscriptServiceErrorMapper {
    static func serviceError(
        for error: TranscriptSizeGuardError
    ) -> EngramServiceError {
        transcriptTooLarge(message: error.localizedDescription)
    }

    static func serviceError(
        for error: ParserFailure
    ) -> EngramServiceError {
        switch error {
        case .fileTooLarge:
            return transcriptTooLarge(
                message: "Archive transcript exceeds the parser size limit"
            )
        default:
            return commandFailed(
                name: "archiveParseFailed",
                message: "The authoritative archive transcript parser rejected the selected bytes",
                retryPolicy: "never"
            )
        }
    }

    static func serviceError(
        for error: ArchiveTranscriptResolverError
    ) -> EngramServiceError {
        switch error {
        case .invalidSessionID:
            return .invalidRequest(message: "Invalid archive session id")
        case .archiveUnavailable:
            return commandFailed(
                name: "archiveUnavailable",
                message: "No verified transcript source is currently available",
                retryPolicy: "safe"
            )
        case .archiveCorrupt:
            return commandFailed(
                name: "archiveCorrupt",
                message: "Verified archive transcript data failed integrity validation",
                retryPolicy: "never"
            )
        case .archiveParseFailed:
            return commandFailed(
                name: "archiveParseFailed",
                message: "The authoritative archive transcript parser rejected the selected bytes",
                retryPolicy: "never"
            )
        case .liveUnavailable, .temporaryStorageFailure, .unsafeTemporaryParent:
            return commandFailed(
                name: "archiveTemporarilyUnavailable",
                message: "Archive transcript storage is temporarily unavailable",
                retryPolicy: "safe"
            )
        case .unsafeLiveFile:
            return commandFailed(
                name: "archiveUnsafeSource",
                message: "The live transcript source is not a safe regular file",
                retryPolicy: "never"
            )
        case .invalidReplicaBackend:
            return commandFailed(
                name: "archiveConfigurationInvalid",
                message: "Archive transcript replica configuration is invalid",
                retryPolicy: "never"
            )
        }
    }

    private static func commandFailed(
        name: String,
        message: String,
        retryPolicy: String
    ) -> EngramServiceError {
        .commandFailed(
            name: name,
            message: message,
            retryPolicy: retryPolicy,
            details: nil
        )
    }

    private static func transcriptTooLarge(message: String) -> EngramServiceError {
        .commandFailed(
            name: "transcriptTooLarge",
            message: message,
            retryPolicy: "never",
            details: ["code": .string("transcriptTooLarge")]
        )
    }

}

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

enum WebWriteRoutes {
    typealias AddWriter = @Sendable (EngramServiceWebAddAliasRequest) async throws -> EngramServiceWebAliasMutationResponse
    typealias RemoveWriter = @Sendable (EngramServiceWebRemoveAliasRequest) async throws -> EngramServiceWebAliasMutationResponse
    typealias SourceWriter = @Sendable (EngramServiceWebSetSourceEnabledRequest) async throws -> EngramServiceWebSetSourceEnabledResponse
    typealias LinkWriter = @Sendable (EngramServiceWebLinkRequest) async throws -> EngramServiceWebRelationshipMutationResponse
    typealias UnlinkWriter = @Sendable (EngramServiceWebUnlinkRequest) async throws -> EngramServiceWebRelationshipMutationResponse
    typealias ConfirmWriter = @Sendable (EngramServiceWebConfirmSuggestionRequest) async throws -> EngramServiceWebRelationshipMutationResponse
    typealias DismissWriter = @Sendable (EngramServiceWebDismissSuggestionRequest) async throws -> EngramServiceWebRelationshipMutationResponse
    typealias InsightWriter = @Sendable (EngramServiceWebSaveInsightRequest) async throws -> EngramServiceWebSaveInsightResponse
    typealias SummaryWriter = @Sendable (EngramServiceWebGenerateSummaryRequest) async throws -> EngramServiceWebGenerateSummaryResponse
    typealias TitleWriter = @Sendable (EngramServiceWebGenerateTitleRequest) async throws -> EngramServiceWebGenerateTitleResponse
    typealias Regenerator = @Sendable (EngramServiceWebRegenerateTitlesRequest) async throws -> EngramServiceWebRegenerateTitlesResponse
    typealias AiSettingsWriter = @Sendable (EngramServiceWebPatchAiSettingsRequest) async throws -> EngramServiceWebAiSettingsResponse
    typealias ProjectMigrationsReader = @Sendable (EngramServiceWebProjectMigrationsRequest) async throws -> EngramServiceWebProjectMigrationsResponse
    typealias ProjectMoveWriter = @Sendable (EngramServiceWebProjectMoveRequest) async throws -> EngramServiceWebProjectMoveResponse
    typealias ProjectArchiveWriter = @Sendable (EngramServiceWebProjectArchiveRequest) async throws -> EngramServiceWebProjectMoveResponse
    typealias ProjectUndoWriter = @Sendable (EngramServiceWebProjectUndoRequest) async throws -> EngramServiceWebProjectMoveResponse
    typealias ProjectMoveBatchWriter = @Sendable (EngramServiceWebProjectMoveBatchRequest) async throws -> EngramServiceWebProjectMoveBatchResponse
    typealias ProjectCancelWriter = @Sendable (EngramServiceWebCancelProjectMoveBatchRequest) async throws -> EngramServiceWebCancelProjectMoveBatchResponse

    struct Surface: Sendable {
        var addAlias: AddWriter
        var removeAlias: RemoveWriter
        var setSourceEnabled: SourceWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var link: LinkWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var unlink: UnlinkWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var confirmSuggestion: ConfirmWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var dismissSuggestion: DismissWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var saveInsight: InsightWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var generateSummary: SummaryWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var generateTitle: TitleWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var regenerateTitles: Regenerator = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var patchAiSettings: AiSettingsWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var projectMigrations: ProjectMigrationsReader = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var projectMove: ProjectMoveWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var projectArchive: ProjectArchiveWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var projectUndo: ProjectUndoWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var projectMoveBatch: ProjectMoveBatchWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
        var cancelProjectMoveBatch: ProjectCancelWriter = { _ in throw EngramServiceWebWriteClientError.unsupported }
    }

    typealias ClientFactory = @Sendable (String) throws -> Surface
    private static let maximumBodyBytes = 4_096
    private static let maximumInsightBodyBytes = 256 * 1_024
    private static let addKeys: Set<String> = ["canonical", "alias"]
    private static let removeKeys: Set<String> = ["alias", "canonical"]
    private static let sourceKeys: Set<String> = ["source", "enabled"]
    private static let linkKeys: Set<String> = ["parentId"]
    private static let unlinkKeys: Set<String> = []
    private static let suggestionKeys: Set<String> = ["suggestedParentId"]
    private static let insightRequiredKeys: Set<String> = ["content"]
    private static let insightAllowedKeys: Set<String> = ["content", "wing", "room", "importance", "sourceSessionId"]
    private static let generationKeys: Set<String> = ["generation"]
    private static let regenerateKeys: Set<String> = []
    private static let aiSettingsKeys = EngramServiceWebAiSettingsValidation.patchKeys
    private static let maximumAiSettingsBodyBytes = 32 * 1_024
    private static let moveKeys: Set<String> = ["src", "dst", "dry_run", "operation_id"]
    private static let moveOptionalKeys: Set<String> = ["force", "audit_note"]
    private static let archiveKeys: Set<String> = ["src", "dry_run", "operation_id"]
    private static let archiveOptionalKeys: Set<String> = ["archive_to", "force", "audit_note"]
    private static let undoKeys: Set<String> = ["migration_id", "operation_id"]
    private static let undoOptionalKeys: Set<String> = ["force"]
    private static let batchKeys: Set<String> = ["yaml", "dry_run", "operation_id"]
    private static let batchOptionalKeys: Set<String> = ["force"]
    private static let cancelKeys: Set<String> = ["operation_id"]
    private static let maximumProjectBodyBytes = EngramServiceWebProjectValidation.maximumBatchBytes

    static func makeSurface(socketPath: String) throws -> Surface {
        let client = try EngramServiceWebWriteClient(socketPath: socketPath)
        return Surface(
            addAlias: { request in try await client.addAlias(request) },
            removeAlias: { request in try await client.removeAlias(request) },
            setSourceEnabled: { request in try await client.setSourceEnabled(request) },
            link: { request in try await client.link(request) },
            unlink: { request in try await client.unlink(request) },
            confirmSuggestion: { request in try await client.confirmSuggestion(request) },
            dismissSuggestion: { request in try await client.dismissSuggestion(request) },
            saveInsight: { request in try await client.saveInsight(request) },
            generateSummary: { request in try await client.generateSummary(request) },
            generateTitle: { request in try await client.generateTitle(request) },
            regenerateTitles: { request in try await client.regenerateTitles(request) },
            patchAiSettings: { request in try await client.patchAiSettings(request) },
            projectMigrations: { request in try await client.projectMigrations(request) },
            projectMove: { request in try await client.projectMove(request) },
            projectArchive: { request in try await client.projectArchive(request) },
            projectUndo: { request in try await client.projectUndo(request) },
            projectMoveBatch: { request in try await client.projectMoveBatch(request) },
            cancelProjectMoveBatch: { request in try await client.cancelProjectMoveBatch(request) }
        )
    }

    static func mount<Context: RequestContext>(on router: Router<Context>, surface: Surface) {
        router.post("/web/api/settings/aliases") { request, _ in
            try await mutate(request, keys: addKeys) { data in
                try await surface.addAlias(try JSONDecoder().decode(EngramServiceWebAddAliasRequest.self, from: data))
            }
        }
        router.delete("/web/api/settings/aliases") { request, _ in
            try await mutate(request, keys: removeKeys) { data in
                try await surface.removeAlias(try JSONDecoder().decode(EngramServiceWebRemoveAliasRequest.self, from: data))
            }
        }
        router.post("/web/api/settings/sources") { request, _ in
            try await mutate(request, keys: sourceKeys) { data in
                try await surface.setSourceEnabled(
                    try JSONDecoder().decode(EngramServiceWebSetSourceEnabledRequest.self, from: data)
                )
            }
        }
        router.post("/web/api/sessions/:id/link") { request, context in
            try await mutate(request, keys: linkKeys) { data in
                let body = try JSONDecoder().decode(ParentIdBody.self, from: data)
                return try await surface.link(try EngramServiceWebLinkRequest(
                    sessionId: try pathSessionID(context.parameters.get("id")), parentId: body.parentId
                ))
            }
        }
        router.delete("/web/api/sessions/:id/link") { request, context in
            try await mutate(request, keys: unlinkKeys) { _ in
                try await surface.unlink(try EngramServiceWebUnlinkRequest(
                    sessionId: try pathSessionID(context.parameters.get("id"))
                ))
            }
        }
        router.post("/web/api/sessions/:id/confirm-suggestion") { request, context in
            try await mutate(request, keys: suggestionKeys) { data in
                let body = try JSONDecoder().decode(SuggestedParentBody.self, from: data)
                return try await surface.confirmSuggestion(try EngramServiceWebConfirmSuggestionRequest(
                    sessionId: try pathSessionID(context.parameters.get("id")),
                    suggestedParentId: body.suggestedParentId
                ))
            }
        }
        router.delete("/web/api/sessions/:id/suggestion") { request, context in
            try await mutate(request, keys: suggestionKeys) { data in
                let body = try JSONDecoder().decode(SuggestedParentBody.self, from: data)
                return try await surface.dismissSuggestion(try EngramServiceWebDismissSuggestionRequest(
                    sessionId: try pathSessionID(context.parameters.get("id")),
                    suggestedParentId: body.suggestedParentId
                ))
            }
        }
        router.post("/web/api/insights") { request, _ in
            try await mutate(
                request,
                required: insightRequiredKeys,
                allowed: insightAllowedKeys,
                maximumBodyBytes: maximumInsightBodyBytes
            ) { data in
                try await surface.saveInsight(try JSONDecoder().decode(EngramServiceWebSaveInsightRequest.self, from: data))
            }
        }
        router.post("/web/api/sessions/:id/summary") { request, context in
            try await mutate(request, keys: generationKeys) { data in
                let body = try JSONDecoder().decode(GenerationBody.self, from: data)
                return try await surface.generateSummary(try EngramServiceWebGenerateSummaryRequest(
                    sessionId: try pathSessionID(context.parameters.get("id")), generation: body.generation
                ))
            }
        }
        router.post("/web/api/sessions/:id/title") { request, context in
            try await mutate(request, keys: generationKeys) { data in
                let body = try JSONDecoder().decode(GenerationBody.self, from: data)
                return try await surface.generateTitle(try EngramServiceWebGenerateTitleRequest(
                    sessionId: try pathSessionID(context.parameters.get("id")), generation: body.generation
                ))
            }
        }
        router.post("/web/api/titles/regenerate") { request, _ in
            try await mutate(request, keys: regenerateKeys) { data in
                try await surface.regenerateTitles(
                    try JSONDecoder().decode(EngramServiceWebRegenerateTitlesRequest.self, from: data)
                )
            }
        }
        router.post("/web/api/settings/ai") { request, _ in
            try await mutate(
                request,
                required: [],
                allowed: aiSettingsKeys,
                maximumBodyBytes: maximumAiSettingsBodyBytes,
                requireNonempty: true
            ) { data in
                try await surface.patchAiSettings(
                    try JSONDecoder().decode(EngramServiceWebPatchAiSettingsRequest.self, from: data)
                )
            }
        }
        router.get("/web/api/migrations") { request, _ in
            let input: EngramServiceWebProjectMigrationsRequest
            do { input = try migrationsRequest(request) } catch { return Response(status: .badRequest) }
            do {
                try Task.checkCancellation()
                let page = try await surface.projectMigrations(input)
                try Task.checkCancellation()
                return EngramRemoteServerApp.json(try JSONEncoder().encode(page))
            } catch let error as EngramServiceWebWriteClientError {
                return writeFailure(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Response(status: .serviceUnavailable)
            }
        }
        router.post("/web/api/projects/move") { request, _ in
            try await mutate(
                request, required: moveKeys, allowed: moveKeys.union(moveOptionalKeys)
            ) { data in
                try await surface.projectMove(try JSONDecoder().decode(EngramServiceWebProjectMoveRequest.self, from: data))
            }
        }
        router.post("/web/api/projects/archive") { request, _ in
            try await mutate(
                request, required: archiveKeys, allowed: archiveKeys.union(archiveOptionalKeys)
            ) { data in
                try await surface.projectArchive(
                    try JSONDecoder().decode(EngramServiceWebProjectArchiveRequest.self, from: data)
                )
            }
        }
        router.post("/web/api/projects/undo") { request, _ in
            try await mutate(
                request, required: undoKeys, allowed: undoKeys.union(undoOptionalKeys)
            ) { data in
                try await surface.projectUndo(try JSONDecoder().decode(EngramServiceWebProjectUndoRequest.self, from: data))
            }
        }
        router.post("/web/api/projects/move-batch") { request, _ in
            try await mutate(
                request,
                required: batchKeys,
                allowed: batchKeys.union(batchOptionalKeys),
                maximumBodyBytes: maximumProjectBodyBytes
            ) { data in
                try await surface.projectMoveBatch(
                    try JSONDecoder().decode(EngramServiceWebProjectMoveBatchRequest.self, from: data)
                )
            }
        }
        router.post("/web/api/projects/move-batch/cancel") { request, _ in
            try await mutate(request, keys: cancelKeys) { data in
                try await surface.cancelProjectMoveBatch(
                    try JSONDecoder().decode(EngramServiceWebCancelProjectMoveBatchRequest.self, from: data)
                )
            }
        }
    }

    private struct ParentIdBody: Decodable {
        let parentId: String
    }

    private struct SuggestedParentBody: Decodable {
        let suggestedParentId: String
    }

    private struct GenerationBody: Decodable {
        let generation: String
    }

    private static func pathSessionID(_ raw: String?) throws -> String {
        guard let raw, raw.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              let decoded = raw.removingPercentEncoding,
              !decoded.isEmpty, decoded != ".", decoded != "..",
              !decoded.contains("/"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        return decoded
    }

    private static func mutate<Result: Encodable>(
        _ request: Request,
        keys: Set<String>,
        operation: (Data) async throws -> Result
    ) async throws -> Response {
        try await mutate(request, required: keys, allowed: keys, operation: operation)
    }

    private static func mutate<Result: Encodable>(
        _ request: Request,
        required: Set<String>,
        allowed: Set<String>,
        maximumBodyBytes: Int = maximumBodyBytes,
        requireNonempty: Bool = false,
        operation: (Data) async throws -> Result
    ) async throws -> Response {
        let data: Data
        do {
            data = try await readJSONBody(request, maximumBodyBytes: maximumBodyBytes)
        } catch {
            return Response(status: .badRequest)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let objectKeys = JSONObjectKeys.uniqueTopLevelKeys(in: data) else {
            return Response(status: .badRequest)
        }
        let keys = Set(objectKeys)
        guard required.isSubset(of: keys), keys.isSubset(of: allowed),
              !requireNonempty || !keys.isEmpty else {
            return Response(status: .badRequest)
        }
        do {
            try Task.checkCancellation()
            let result = try await operation(data)
            try Task.checkCancellation()
            return EngramRemoteServerApp.json(try JSONEncoder().encode(result))
        } catch let error as EngramServiceWebWriteClientError {
            return writeFailure(error)
        } catch is DecodingError, is EngramServiceWebReadError {
            return Response(status: .badRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Response(status: .serviceUnavailable)
        }
    }

    private static func writeFailure(_ error: EngramServiceWebWriteClientError) -> Response {
        switch error {
        case .invalid: return Response(status: .badRequest)
        case .stale: return Response(status: .conflict)
        case .notFound: return Response(status: .notFound)
        case .unsupported, .unavailable: return Response(status: .serviceUnavailable)
        case .malformed: return Response(status: .badGateway)
        case .project(let failure):
            let status: HTTPResponse.Status
            switch failure.category {
            case "confinement", "invalid": status = .badRequest
            case "conflict", "cancelled": status = .conflict
            default: status = .serviceUnavailable
            }
            guard let body = try? JSONEncoder().encode(failure) else {
                return Response(status: status)
            }
            var response = EngramRemoteServerApp.json(body)
            response.status = status
            return response
        }
    }

    private static func migrationsRequest(_ request: Request) throws -> EngramServiceWebProjectMigrationsRequest {
        guard !request.uri.string.contains("#") else { throw EngramServiceWebReadError.invalidField("query") }
        guard let query = request.uri.query, !query.isEmpty else {
            return try EngramServiceWebProjectMigrationsRequest()
        }
        guard query.utf8.count <= 4_096 else { throw EngramServiceWebReadError.invalidField("query") }
        var state: String?
        var limit: Int?
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let name = String(pair[0]).removingPercentEncoding,
                  let value = String(pair[1]).removingPercentEncoding else {
                throw EngramServiceWebReadError.invalidField("query")
            }
            switch name {
            case "state":
                guard state == nil else { throw EngramServiceWebReadError.invalidField("state") }
                state = value
            case "limit":
                guard limit == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int(value), String(parsed) == value else {
                    throw EngramServiceWebReadError.invalidField("limit")
                }
                limit = parsed
            default:
                throw EngramServiceWebReadError.invalidField("query")
            }
        }
        return try EngramServiceWebProjectMigrationsRequest(state: state, limit: limit ?? 50)
    }

    private static func readJSONBody(_ request: Request, maximumBodyBytes: Int = maximumBodyBytes) async throws -> Data {
        let values = request.headers[values: .contentType]
        guard values.count == 1 else { throw WriteBodyError.unsupportedMediaType }
        let parts = values[0].lowercased().split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts == ["application/json"] || parts == ["application/json", "charset=utf-8"] else {
            throw WriteBodyError.unsupportedMediaType
        }
        do {
            let buffer = try await request.body.collect(upTo: maximumBodyBytes)
            return Data(buffer.readableBytesView)
        } catch {
            throw WriteBodyError.tooLarge
        }
    }

    private enum WriteBodyError: Error {
        case unsupportedMediaType
        case tooLarge
    }
}

private enum JSONObjectKeys {
    static func uniqueTopLevelKeys(in data: Data) -> [String]? {
        var index = data.startIndex
        skipWhitespace(data, index: &index)
        guard index < data.endIndex, data[index] == 0x7b else { return nil }
        index += 1
        skipWhitespace(data, index: &index)
        if index < data.endIndex, data[index] == 0x7d { return [] }
        var keys: [String] = []
        var seen = Set<String>()
        while index < data.endIndex {
            skipWhitespace(data, index: &index)
            guard let key = parseString(data, index: &index) else { return nil }
            guard seen.insert(key).inserted else { return nil }
            keys.append(key)
            skipWhitespace(data, index: &index)
            guard index < data.endIndex, data[index] == 0x3a else { return nil }
            index += 1
            guard skipValue(data, index: &index) else { return nil }
            skipWhitespace(data, index: &index)
            if index < data.endIndex, data[index] == 0x2c {
                index += 1
                continue
            }
            guard index < data.endIndex, data[index] == 0x7d else { return nil }
            index += 1
            skipWhitespace(data, index: &index)
            return index == data.endIndex ? keys : nil
        }
        return nil
    }

    private static func skipWhitespace(_ data: Data, index: inout Data.Index) {
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d { index += 1 }
            else { return }
        }
    }

    private static func parseString(_ data: Data, index: inout Data.Index) -> String? {
        guard index < data.endIndex, data[index] == 0x22 else { return nil }
        let start = index
        index += 1
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            if escaped { escaped = false }
            else if byte == 0x5c { escaped = true }
            else if byte == 0x22 {
                index += 1
                guard let object = try? JSONSerialization.jsonObject(with: Data([0x5b]) + data[start..<index] + Data([0x5d])) as? [Any],
                      let value = object.first as? String else { return nil }
                return value
            }
            index += 1
        }
        return nil
    }

    private static func skipValue(_ data: Data, index: inout Data.Index) -> Bool {
        skipWhitespace(data, index: &index)
        guard index < data.endIndex else { return false }
        switch data[index] {
        case 0x22:
            return parseString(data, index: &index) != nil
        case 0x7b:
            return skipContainer(data, index: &index, open: 0x7b, close: 0x7d)
        case 0x5b:
            return skipContainer(data, index: &index, open: 0x5b, close: 0x5d)
        case 0x74:
            return skipLiteral(data, index: &index, "true")
        case 0x66:
            return skipLiteral(data, index: &index, "false")
        case 0x6e:
            return skipLiteral(data, index: &index, "null")
        default:
            return skipNumber(data, index: &index)
        }
    }

    private static func skipLiteral(_ data: Data, index: inout Data.Index, _ literal: String) -> Bool {
        let bytes = Array(literal.utf8)
        guard data[index..<data.endIndex].starts(with: bytes) else { return false }
        index += bytes.count
        return true
    }

    private static func skipNumber(_ data: Data, index: inout Data.Index) -> Bool {
        let start = index
        while index < data.endIndex {
            let byte = data[index]
            if (48...57).contains(byte) || byte == 0x2d || byte == 0x2b || byte == 0x2e || byte == 0x65 || byte == 0x45 {
                index += 1
            } else {
                break
            }
        }
        return index > start
    }

    private static func skipContainer(_ data: Data, index: inout Data.Index, open: UInt8, close: UInt8) -> Bool {
        guard index < data.endIndex, data[index] == open else { return false }
        var depth = 0
        var inString = false
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
            } else if byte == 0x22 {
                inString = true
            } else if byte == open {
                depth += 1
            } else if byte == close {
                depth -= 1
                index += 1
                if depth == 0 { return true }
                continue
            }
            index += 1
        }
        return false
    }
}

import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import NIOCore

enum ArchivePublicationRoutes {
    static func mount(
        on router: Router<BasicRequestContext>,
        store: ArchiveStore,
        token: String,
        serverID: String
    ) {
        router.get("/v2/archive/publication-capabilities") { request, _ in
            guard EngramRemoteServerApp.authorized(request, token: token) else { return unauthorized() }
            do {
                // Protocol support is static; this is not an intake-readiness claim.
                return try jsonResponse(
                    CollectorPublicationCapabilities(serverID: serverID),
                    maximumBytes: CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes
                )
            } catch {
                return errorResponse(status: .internalServerError, code: .internalError)
            }
        }

        router.put("/v2/archive/publications/:digest") { request, context in
            guard EngramRemoteServerApp.authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"), ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: .malformedRequest)
            }
            guard let contentType = request.headers[.contentType],
                  let mediaType = MediaType(from: contentType), mediaType.isType(.applicationJson) else {
                return errorResponse(status: status(415, "Unsupported Media Type"), code: .unsupportedMediaType)
            }

            let bytes: Data
            do {
                var request = request
                let body = try await request.collectBody(upTo: CollectorPublicationProtocolLimits.maxPublicationBytes)
                bytes = Data(body.readableBytesView)
            } catch is NIOTooManyBytesError {
                return errorResponse(status: status(413, "Payload Too Large"), code: .payloadTooLarge)
            } catch {
                return errorResponse(status: .serviceUnavailable, code: .storageUnavailable)
            }
            do {
                _ = try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: bytes)
                guard ArchiveV2Hash.sha256(bytes) == digest else {
                    return errorResponse(status: .badRequest, code: .malformedRequest)
                }
            } catch {
                return errorResponse(status: .badRequest, code: .malformedRequest)
            }
            do {
                let acceptance = try store.acceptPublication(digest: digest, canonicalBytes: bytes)
                return try jsonResponse(
                    acceptance.record.ack,
                    status: acceptance.result == .published ? .created : .ok,
                    maximumBytes: CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.get("/v2/archive/publications/:digest") { request, context in
            guard EngramRemoteServerApp.authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"), ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: .malformedRequest)
            }
            do {
                return try jsonResponse(
                    store.getPublication(digest: digest),
                    maximumBytes: CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.get("/v2/archive/publications") { request, _ in
            guard EngramRemoteServerApp.authorized(request, token: token) else { return unauthorized() }
            let parameters: (cursor: String?, limit: Int)
            do {
                parameters = try pageParameters(request)
            } catch {
                return errorResponse(status: .badRequest, code: .malformedRequest)
            }
            do {
                return try jsonResponse(
                    store.listPublications(cursor: parameters.cursor, limit: parameters.limit),
                    maximumBytes: CollectorPublicationProtocolLimits.maxPageBytes
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        // ArchiveRoutes owns the authenticated DELETE -> 405 guard, including
        // these exact paths: method lookup does not fall back to its wildcard
        // after a matching GET/PUT path is found. Do not add another handler here.
    }

    private static func pageParameters(_ request: Request) throws -> (cursor: String?, limit: Int) {
        let query = request.uri.queryParameters
        guard query.allSatisfy({ $0.key == "cursor" || $0.key == "limit" }) else {
            throw ArchiveStoreError.invalidPage
        }
        let cursorValues = query[values: "cursor"]
        let limitValues = query[values: "limit"]
        guard cursorValues.count <= 1, limitValues.count <= 1 else {
            throw ArchiveStoreError.invalidPage
        }
        let cursor = cursorValues.first.map(String.init)
        if let cursor { _ = try CollectorPublicationCursor.decode(cursor) }
        let limit = try CollectorPublicationProtocolLimits.validatedPageLimit(limitValues.first.map(String.init))
        return (cursor, limit)
    }

    static func storeErrorResponse(_ error: Error) -> Response {
        if let error = error as? ArchivePublicationStoreError {
            switch error {
            case .sequenceConflict:
                return errorResponse(status: .conflict, code: .sequenceConflict)
            case .cursorJournalMismatch:
                return errorResponse(status: .conflict, code: .cursorJournalMismatch)
            case .cursorAheadOfTail:
                return errorResponse(status: .conflict, code: .cursorAheadOfTail)
            case .invalidPublication:
                return errorResponse(status: status(422, "Unprocessable Content"), code: .invalidContent)
            case .unavailable, .ordinalOverflow:
                return errorResponse(status: .serviceUnavailable, code: .storageUnavailable)
            }
        }
        if let error = error as? ArchiveStoreError {
            switch error {
            case .invalidDigest, .invalidMachineID, .invalidPage, .digestMismatch:
                return errorResponse(status: .badRequest, code: .malformedRequest)
            case .notFound:
                return errorResponse(status: .notFound, code: .notFound)
            case .tooLarge:
                return errorResponse(status: status(413, "Payload Too Large"), code: .payloadTooLarge)
            case .invalidManifest, .missingReference, .unboundManifest:
                return errorResponse(status: status(422, "Unprocessable Content"), code: .invalidContent)
            case .conflict, .invalidReceipt, .io:
                return errorResponse(status: .serviceUnavailable, code: .storageUnavailable)
            }
        }
        return errorResponse(status: .internalServerError, code: .internalError)
    }

    private static func jsonResponse<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status = .ok,
        maximumBytes: Int
    ) throws -> Response {
        let bytes = try ArchiveCanonicalJSON.encode(value)
        guard bytes.count <= maximumBytes else {
            return errorResponse(status: .internalServerError, code: .internalError)
        }
        return dataResponse(bytes, status: status)
    }

    private static func unauthorized() -> Response {
        errorResponse(status: .unauthorized, code: .unauthorized, authenticate: true)
    }

    private static func errorResponse(
        status: HTTPResponse.Status,
        code: CollectorPublicationErrorCode,
        authenticate: Bool = false
    ) -> Response {
        let bytes = Data("{\"error\":\"\(code.rawValue)\"}".utf8)
        var response = dataResponse(bytes, status: status)
        if authenticate { response.headers[.wwwAuthenticate] = "Bearer" }
        return response
    }

    private static func dataResponse(_ bytes: Data, status: HTTPResponse.Status) -> Response {
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
        headers[.contentLength] = "\(bytes.count)"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: bytes)))
    }

    private static func status(_ code: Int, _ reason: String) -> HTTPResponse.Status {
        HTTPResponse.Status(code: code, reasonPhrase: reason)
    }
}

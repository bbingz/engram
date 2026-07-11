import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import NIOCore

enum ArchiveRoutes {
    private enum RequestError: Error {
        case malformed
    }

    static func mount(
        on router: Router<BasicRequestContext>,
        store: ArchiveStore,
        token: String
    ) {
        router.put("/v2/archive/objects/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            guard hasContentType(request, matching: .applicationBinary) else {
                return errorResponse(status: status(415, "Unsupported Media Type"), code: "unsupported_media_type")
            }
            let raw: Data
            do {
                raw = try await collectBody(
                    request,
                    upTo: ArchiveV2ProtocolLimits.maxObjectRawBytes
                )
            } catch is NIOTooManyBytesError {
                return errorResponse(status: status(413, "Payload Too Large"), code: "payload_too_large")
            } catch {
                return errorResponse(status: .serviceUnavailable, code: "storage_unavailable")
            }
            do {
                let result = try store.putObject(digest: digest, raw: raw)
                return emptyResponse(status: publicationStatus(result))
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.head("/v2/archive/objects/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            do {
                let raw = try store.getObject(digest: digest)
                return emptyResponse(
                    status: .ok,
                    contentType: "application/octet-stream",
                    contentLength: raw.count
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.get("/v2/archive/objects/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            do {
                return dataResponse(
                    try store.getObject(digest: digest),
                    status: .ok,
                    contentType: "application/octet-stream"
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.put("/v2/archive/manifests/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            guard hasContentType(request, matching: .applicationJson) else {
                return errorResponse(status: status(415, "Unsupported Media Type"), code: "unsupported_media_type")
            }
            let bytes: Data
            do {
                bytes = try await collectBody(
                    request,
                    upTo: ArchiveV2ProtocolLimits.maxManifestBytes
                )
            } catch is NIOTooManyBytesError {
                return errorResponse(status: status(413, "Payload Too Large"), code: "payload_too_large")
            } catch {
                return errorResponse(status: .serviceUnavailable, code: "storage_unavailable")
            }
            do {
                let result = try store.putManifest(digest: digest, canonicalBytes: bytes)
                return emptyResponse(status: publicationStatus(result))
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.head("/v2/archive/manifests/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            do {
                let bytes = try store.getManifest(digest: digest)
                return emptyResponse(
                    status: .ok,
                    contentType: "application/json; charset=utf-8",
                    contentLength: bytes.count
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.get("/v2/archive/manifests/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            do {
                return dataResponse(
                    try store.getManifest(digest: digest),
                    status: .ok,
                    contentType: "application/json; charset=utf-8"
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.put("/v2/archive/receipts/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            do {
                let body = try await collectBody(request, upTo: 0)
                guard body.isEmpty else {
                    return errorResponse(status: .badRequest, code: "malformed_request")
                }
            } catch is NIOTooManyBytesError {
                return errorResponse(status: status(413, "Payload Too Large"), code: "payload_too_large")
            } catch {
                return errorResponse(status: .serviceUnavailable, code: "storage_unavailable")
            }
            do {
                let creation = try store.createReceiptWithResult(manifestDigest: digest)
                return dataResponse(
                    creation.bytes,
                    status: publicationStatus(creation.result),
                    contentType: "application/json; charset=utf-8"
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.get("/v2/archive/receipts/:digest") { request, context in
            guard authorized(request, token: token) else { return unauthorized() }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return errorResponse(status: .badRequest, code: "malformed_request")
            }
            do {
                return dataResponse(
                    try store.getReceipt(manifestDigest: digest),
                    status: .ok,
                    contentType: "application/json; charset=utf-8"
                )
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.get("/v2/archive/machines") { request, _ in
            guard authorized(request, token: token) else { return unauthorized() }
            do {
                let parameters = try pageParameters(
                    request,
                    allowedKeys: ["cursor", "limit"]
                )
                let page = try store.listMachines(
                    cursor: parameters.cursor,
                    limit: parameters.limit
                )
                return try pageResponse(page)
            } catch let error as RequestError {
                return requestErrorResponse(error)
            } catch {
                return storeErrorResponse(error)
            }
        }

        router.get("/v2/archive/receipts") { request, _ in
            guard authorized(request, token: token) else { return unauthorized() }
            do {
                let query = request.uri.queryParameters
                try validateQueryKeys(query, allowed: ["machine_id", "cursor", "limit"])
                let machineValues = query[values: "machine_id"]
                guard machineValues.count == 1 else { throw RequestError.malformed }
                let parameters = try pageParameters(
                    request,
                    allowedKeys: ["machine_id", "cursor", "limit"]
                )
                let page = try store.listReceipts(
                    machineID: String(machineValues[0]),
                    cursor: parameters.cursor,
                    limit: parameters.limit
                )
                return try pageResponse(page)
            } catch let error as RequestError {
                return requestErrorResponse(error)
            } catch {
                return storeErrorResponse(error)
            }
        }

        for path in [
            "/v2/archive",
            "/v2/archive/objects/:digest",
            "/v2/archive/manifests/:digest",
            "/v2/archive/receipts/:digest",
            "/v2/archive/receipts",
            "/v2/archive/machines",
        ] {
            router.delete(RouterPath(path)) { request, _ in
                guard authorized(request, token: token) else { return unauthorized() }
                return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")
            }
        }
        router.delete("/v2/archive/**") { request, _ in
            guard authorized(request, token: token) else { return unauthorized() }
            return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")
        }
    }

    private static func authorized(_ request: Request, token: String) -> Bool {
        EngramRemoteServerApp.authorized(request, token: token)
    }

    private static func hasContentType(_ request: Request, matching expected: MediaType) -> Bool {
        guard let header = request.headers[.contentType],
              let mediaType = MediaType(from: header) else {
            return false
        }
        return mediaType.isType(expected)
    }

    private static func collectBody(_ request: Request, upTo maximumBytes: Int) async throws -> Data {
        var request = request
        let buffer = try await request.collectBody(upTo: maximumBytes)
        return Data(buffer.readableBytesView)
    }

    private static func pageParameters(
        _ request: Request,
        allowedKeys: Set<String>
    ) throws -> (cursor: String?, limit: Int) {
        let query = request.uri.queryParameters
        try validateQueryKeys(query, allowed: allowedKeys)
        let cursorValues = query[values: "cursor"]
        let limitValues = query[values: "limit"]
        guard cursorValues.count <= 1, limitValues.count <= 1 else {
            throw RequestError.malformed
        }
        let cursor = cursorValues.first.map(String.init)
        do {
            try ArchiveV2ProtocolLimits.validateCursor(cursor)
            let limit = try ArchiveV2ProtocolLimits.validatedPageLimit(
                limitValues.first.map(String.init)
            )
            return (cursor, limit)
        } catch {
            throw RequestError.malformed
        }
    }

    private static func validateQueryKeys(
        _ query: FlatDictionary<Substring, Substring>,
        allowed: Set<String>
    ) throws {
        guard query.allSatisfy({ allowed.contains(String($0.key)) }) else {
            throw RequestError.malformed
        }
    }

    private static func pageResponse<T: Encodable>(_ page: T) throws -> Response {
        let bytes = try ArchiveCanonicalJSON.encode(page)
        guard bytes.count <= ArchiveV2ProtocolLimits.maxPageBytes else {
            return errorResponse(status: .internalServerError, code: "internal_error")
        }
        return dataResponse(
            bytes,
            status: .ok,
            contentType: "application/json; charset=utf-8"
        )
    }

    private static func publicationStatus(_ result: ArchivePublishResult) -> HTTPResponse.Status {
        switch result {
        case .published: .created
        case .alreadyPresent: .ok
        }
    }

    private static func storeErrorResponse(_ error: Error) -> Response {
        guard let error = error as? ArchiveStoreError else {
            return errorResponse(status: .internalServerError, code: "internal_error")
        }
        switch error {
        case .invalidDigest, .invalidMachineID, .invalidPage:
            return errorResponse(status: .badRequest, code: "malformed_request")
        case .notFound:
            return errorResponse(status: .notFound, code: "not_found")
        case .conflict, .missingReference:
            return errorResponse(status: .conflict, code: "conflict")
        case .tooLarge:
            return errorResponse(status: status(413, "Payload Too Large"), code: "payload_too_large")
        case .digestMismatch, .invalidManifest, .invalidReceipt, .unboundManifest:
            return errorResponse(status: status(422, "Unprocessable Content"), code: "invalid_content")
        case .io:
            return errorResponse(status: .serviceUnavailable, code: "storage_unavailable")
        }
    }

    private static func requestErrorResponse(_ error: RequestError) -> Response {
        switch error {
        case .malformed:
            errorResponse(status: .badRequest, code: "malformed_request")
        }
    }

    private static func unauthorized() -> Response {
        errorResponse(status: .unauthorized, code: "unauthorized", authenticate: true)
    }

    private static func errorResponse(
        status: HTTPResponse.Status,
        code: String,
        authenticate: Bool = false
    ) -> Response {
        let data = Data("{\"error\":\"\(code)\"}".utf8)
        precondition(data.count <= ArchiveV2ProtocolLimits.maxErrorBytes)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.contentLength] = "\(data.count)"
        if authenticate {
            headers[.wwwAuthenticate] = "Bearer"
        }
        return Response(
            status: status,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func emptyResponse(
        status: HTTPResponse.Status,
        contentType: String? = nil,
        contentLength: Int? = nil
    ) -> Response {
        var headers = HTTPFields()
        if let contentType { headers[.contentType] = contentType }
        if let contentLength { headers[.contentLength] = "\(contentLength)" }
        return Response(status: status, headers: headers)
    }

    private static func dataResponse(
        _ data: Data,
        status: HTTPResponse.Status,
        contentType: String
    ) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = contentType
        headers[.contentLength] = "\(data.count)"
        return Response(
            status: status,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func status(_ code: Int, _ reason: String) -> HTTPResponse.Status {
        HTTPResponse.Status(code: code, reasonPhrase: reason)
    }
}

import Dispatch
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
        token: String,
        telemetry: ArchiveRemoteTelemetryStore? = nil
    ) {
        router.put("/v2/archive/objects/:digest") { request, context in
            await observed(
                request,
                endpoint: "object",
                telemetry: telemetry,
                archiveMutation: true
            ) {
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
        }

        router.head("/v2/archive/objects/:digest") { request, context in
            await observed(request, endpoint: "object", telemetry: telemetry) {
            guard authorized(request, token: token) else {
                return headOnly(unauthorized())
            }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return headOnly(
                    errorResponse(status: .badRequest, code: "malformed_request")
                )
            }
            do {
                // M14: HEAD must not decrypt full content (dedup probe only).
                guard try store.hasObject(digest: digest) else {
                    return headOnly(Response(status: .notFound))
                }
                return emptyResponse(
                    status: .ok,
                    contentType: "application/octet-stream",
                    contentLength: nil
                )
            } catch {
                return headOnly(storeErrorResponse(error))
            }
            }
        }

        router.get("/v2/archive/objects/:digest") { request, context in
            await observed(request, endpoint: "object", telemetry: telemetry) {
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
        }

        router.put("/v2/archive/manifests/:digest") { request, context in
            await observed(
                request,
                endpoint: "manifest",
                telemetry: telemetry,
                archiveMutation: true
            ) {
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
        }

        router.head("/v2/archive/manifests/:digest") { request, context in
            await observed(request, endpoint: "manifest", telemetry: telemetry) {
            guard authorized(request, token: token) else {
                return headOnly(unauthorized())
            }
            guard let digest = context.parameters.get("digest"),
                  ArchiveV2Hash.isValidSHA256(digest) else {
                return headOnly(
                    errorResponse(status: .badRequest, code: "malformed_request")
                )
            }
            do {
                // M14: HEAD must not re-read every referenced chunk.
                guard try store.hasManifest(digest: digest) else {
                    return headOnly(Response(status: .notFound))
                }
                return emptyResponse(
                    status: .ok,
                    contentType: "application/json; charset=utf-8",
                    contentLength: nil
                )
            } catch {
                return headOnly(storeErrorResponse(error))
            }
            }
        }

        router.get("/v2/archive/manifests/:digest") { request, context in
            await observed(request, endpoint: "manifest", telemetry: telemetry) {
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
        }

        router.put("/v2/archive/receipts/:digest") { request, context in
            await observed(
                request,
                endpoint: "receipt",
                telemetry: telemetry,
                archiveMutation: true
            ) {
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
        }

        router.get("/v2/archive/receipts/:digest") { request, context in
            await observed(request, endpoint: "receipt", telemetry: telemetry) {
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
        }

        router.get("/v2/archive/machines") { request, _ in
            await observed(request, endpoint: "machines", telemetry: telemetry) {
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
        }

        router.get("/v2/archive/receipts") { request, _ in
            await observed(request, endpoint: "receipts", telemetry: telemetry) {
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
        }

        if let telemetry {
            router.get("/v2/archive/status") { request, _ in
                await observed(request, endpoint: "status", telemetry: telemetry) {
                    guard authorized(request, token: token) else { return unauthorized() }
                    let snapshot = await telemetry.status(forcePersist: true)
                    do {
                        let bytes = try ArchiveCanonicalJSON.encode(snapshot)
                        guard bytes.count <= ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes else {
                            return errorResponse(status: .internalServerError, code: "internal_error")
                        }
                        return dataResponse(
                            bytes,
                            status: .ok,
                            contentType: "application/json; charset=utf-8"
                        )
                    } catch {
                        return errorResponse(status: .internalServerError, code: "internal_error")
                    }
                }
            }
        }

        for (path, endpoint) in [
            ("/v2/archive", "unknown"),
            ("/v2/archive/objects/:digest", "object"),
            ("/v2/archive/manifests/:digest", "manifest"),
            ("/v2/archive/receipts/:digest", "receipt"),
            ("/v2/archive/receipts", "receipts"),
            ("/v2/archive/machines", "machines"),
            ("/v2/archive/status", "status"),
        ] {
            router.delete(RouterPath(path)) { request, _ in
                await observed(request, endpoint: endpoint, telemetry: telemetry) {
                    guard authorized(request, token: token) else { return unauthorized() }
                    return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")
                }
            }
        }
        router.delete("/v2/archive/**") { request, _ in
            await observed(request, endpoint: "unknown", telemetry: telemetry) {
                guard authorized(request, token: token) else { return unauthorized() }
                return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")
            }
        }
    }

    private static func observed(
        _ request: Request,
        endpoint: String,
        telemetry: ArchiveRemoteTelemetryStore?,
        archiveMutation: Bool = false,
        operation: () async -> Response
    ) async -> Response {
        let started = DispatchTime.now().uptimeNanoseconds
        let response = await operation()
        guard let telemetry else { return response }
        await telemetry.record(
            ArchiveRemoteTelemetryObservation(
                endpoint: endpoint,
                method: request.method.rawValue,
                statusCode: response.status.code,
                durationMs: elapsedMilliseconds(since: started),
                requestBytes: boundedContentLength(request.headers),
                responseBytes: boundedContentLength(response.headers),
                archiveMutation: archiveMutation && response.status.code < 300
            )
        )
        return response
    }

    private static func elapsedMilliseconds(since started: UInt64) -> Double {
        let finished = DispatchTime.now().uptimeNanoseconds
        guard finished >= started else { return 0 }
        return Double(finished - started) / 1_000_000
    }

    private static func boundedContentLength(_ headers: HTTPFields) -> Int64 {
        guard let value = headers[.contentLength],
              !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int64(value) else {
            return 0
        }
        return count
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

    private static func headOnly(_ response: Response) -> Response {
        Response(status: response.status, headers: response.headers)
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

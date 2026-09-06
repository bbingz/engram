import Foundation

extension EngramServiceCommandHandler {
    static let webMessagesMaximumDuration: Duration = .seconds(2)

    func webMessagesResponse(_ request: EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope {
        let deadline = ContinuousClock.now.advanced(by: Self.webMessagesMaximumDuration)
        func failure(_ name: String, _ message: String, retryPolicy: String) -> EngramServiceResponseEnvelope {
            .failure(requestId: request.requestId, error: .init(name: name, message: message, retryPolicy: retryPolicy))
        }
        do {
            try Self.webMessagesCheckpoint(deadline)
            let input: EngramServiceWebMessagesRequest
            do {
                guard let payload = request.payload,
                      let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      Set(object.keys).isSubset(of: ["sessionId", "generation", "roles", "cursor", "maxFragments"]) else {
                    throw EngramServiceWebReadError.invalidField("payload")
                }
                input = try JSONDecoder().decode(EngramServiceWebMessagesRequest.self, from: payload)
            } catch {
                try Self.webMessagesCheckpoint(deadline)
                return failure("InvalidRequest", "Web transcript request is invalid.", retryPolicy: "never")
            }
            try Self.webMessagesCheckpoint(deadline)
            // Every request, including repeated/continued pages, re-enters the
            // authority provider. Never infer a binding from the request or
            // retain an earlier page's eligibility decision in this handler.
            let snapshot = try await webTranscriptSnapshotProvider.snapshot(
                sessionID: input.sessionId, generation: input.generation, deadline: deadline
            )
            try Self.webMessagesCheckpoint(deadline)
            let page = try ServiceTranscriptContinuation.page(snapshot: snapshot, request: input, requestId: request.requestId)
            let result = try JSONEncoder().encode(page)
            try Self.webMessagesCheckpoint(deadline)
            return .success(requestId: request.requestId, result: result)
        } catch is CancellationError {
            return failure("Cancelled", "Web transcript read was cancelled.", retryPolicy: "never")
        } catch let error as EngramServiceWebReadError {
            switch error {
            case .staleCursor:
                return failure("StaleCursor", "Web transcript continuation is stale.", retryPolicy: "never")
            case .invalidCursor, .invalidField:
                return failure("InvalidRequest", "Web transcript request is invalid.", retryPolicy: "never")
            case .responseTooLarge:
                return failure("ServiceUnavailable", "Web transcript service is unavailable.", retryPolicy: "safe")
            }
        } catch {
            // Provider and encoding failures never reveal filesystem, database,
            // or free-form diagnostic text to this read surface.
            return failure("ServiceUnavailable", "Web transcript service is unavailable.", retryPolicy: "safe")
        }
    }

    /// This bounds acceptance of a result, not arbitrary uncooperative work.
    /// The provider contract requires prepared snapshots and cooperative exit.
    private static func webMessagesCheckpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ServiceWebTranscriptSnapshotError.unavailable }
    }
}

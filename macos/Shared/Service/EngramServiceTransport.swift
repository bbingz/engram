import Foundation

protocol EngramServiceTransport: Sendable {
    func send(
        _ request: EngramServiceRequestEnvelope,
        timeout: TimeInterval?
    ) async throws -> EngramServiceResponseEnvelope

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error>

    func close() async
}

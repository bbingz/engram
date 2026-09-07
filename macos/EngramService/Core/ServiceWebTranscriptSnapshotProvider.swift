import Foundation

/// Supplies an already-prepared immutable snapshot, never a client-provided
/// locator. The provider owns authoritative identity/generation binding and
/// must revalidate read eligibility on every call, including continuation pages.
/// Implementations must cooperate with cancellation and the supplied deadline;
/// this interface does not authorize cold parsing, network recovery, or writes.
protocol ServiceWebTranscriptSnapshotProviding: Sendable {
    /// Advertises an installed normalized reader, not per-session admission or health.
    var supportsNormalizedTranscripts: Bool { get }

    func snapshot(
        sessionID: String,
        generation: String,
        deadline: ContinuousClock.Instant
    ) async throws -> ServiceTranscriptContinuation.Snapshot?
}

extension ServiceWebTranscriptSnapshotProviding {
    var supportsNormalizedTranscripts: Bool { false }
}

enum ServiceWebTranscriptSnapshotError: Error, Equatable, Sendable {
    case unavailable
}

/// Production stays closed until a last-good authority binding is wired in.
struct UnavailableServiceWebTranscriptSnapshotProvider: ServiceWebTranscriptSnapshotProviding {
    func snapshot(
        sessionID: String,
        generation: String,
        deadline: ContinuousClock.Instant
    ) async throws -> ServiceTranscriptContinuation.Snapshot? {
        throw ServiceWebTranscriptSnapshotError.unavailable
    }
}

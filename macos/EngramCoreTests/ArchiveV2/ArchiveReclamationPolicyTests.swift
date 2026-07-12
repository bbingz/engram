import EngramCoreWrite
import XCTest

final class ArchiveReclamationPolicyTests: XCTestCase {
    private let day: Int64 = 86_400_000_000_000
    private let now: Int64 = 2_000_000_000_000_000_000

    func testSupportedHotWindowBoundariesAreInclusive() {
        for days in [30, 60, 90, 180] {
            let result = ArchiveReclamationPolicy.evaluate(
                candidate: candidate(lastActivityNs: now - Int64(days) * day),
                context: context(hotWindowDays: days)
            )
            XCTAssertEqual(result, .eligible, "\(days)-day boundary must be eligible")
        }
        XCTAssertEqual(
            ArchiveReclamationPolicy.evaluate(
                candidate: candidate(lastActivityNs: now - 30 * day + 1),
                context: context(hotWindowDays: 30)
            ),
            .blocked(.insufficientAge)
        )
    }

    func testInvalidWindowsAndUnsupportedSourcesFailClosed() {
        for days in [0, 29, 31, 365] {
            XCTAssertEqual(
                ArchiveReclamationPolicy.evaluate(
                    candidate: candidate(),
                    context: context(hotWindowDays: days)
                ),
                .blocked(.invalidHotWindow)
            )
        }
        for source in ["cursor", "gemini", "claude-code-dispatch"] {
            XCTAssertEqual(
                ArchiveReclamationPolicy.evaluate(
                    candidate: candidate(source: source),
                    context: context()
                ),
                .blocked(.unsupportedSource)
            )
        }
        for source in ["claude-code", "codex"] {
            XCTAssertEqual(
                ArchiveReclamationPolicy.evaluate(
                    candidate: candidate(source: source),
                    context: context()
                ),
                .eligible
            )
        }
    }

    func testEverySafetyGateHasOneBoundedBlocker() {
        let cases: [(ArchiveReclamationCandidate, ArchiveReclamationContext, ArchiveReclamationBlocker)] = [
            (candidate(), context(enabled: false), .disabled),
            (candidate(isLive: true), context(), .live),
            (candidate(isFavorite: true), context(), .favorite),
            (candidate(generationMatchesCapture: false), context(), .generationChanged),
            (candidate(verifiedReceiptReplicaIDs: ["hq"]), context(), .missingReceipt),
            (candidate(), context(recoveryLeaseVerifiedAtNs: ["hq": now, "m1": now - 30 * day - 1]), .expiredDrill),
            (candidate(hasNewerCapture: true), context(), .newerCapture),
            (candidate(hasActiveOperation: true), context(), .activeOperation),
            (candidate(sourceByteCount: 256 * 1_024 * 1_024 + 1), context(), .sourceTooLarge),
        ]
        for (candidate, context, blocker) in cases {
            XCTAssertEqual(
                ArchiveReclamationPolicy.evaluate(candidate: candidate, context: context),
                .blocked(blocker)
            )
        }
    }

    func testBlockerPrecedenceIsDeterministic() {
        let allBlocked = candidate(
            source: "cursor",
            lastActivityNs: now,
            isLive: true,
            isFavorite: true,
            generationMatchesCapture: false,
            verifiedReceiptReplicaIDs: [],
            hasNewerCapture: true,
            hasActiveOperation: true,
            sourceByteCount: 300 * 1_024 * 1_024
        )
        XCTAssertEqual(
            ArchiveReclamationPolicy.evaluate(
                candidate: allBlocked,
                context: context(enabled: false, hotWindowDays: 31, recoveryLeaseVerifiedAtNs: [:])
            ),
            .blocked(.disabled)
        )
        XCTAssertEqual(
            ArchiveReclamationPolicy.evaluate(
                candidate: allBlocked,
                context: context(hotWindowDays: 31, recoveryLeaseVerifiedAtNs: [:])
            ),
            .blocked(.invalidHotWindow)
        )
        XCTAssertEqual(
            ArchiveReclamationPolicy.evaluate(
                candidate: allBlocked,
                context: context(recoveryLeaseVerifiedAtNs: [:])
            ),
            .blocked(.unsupportedSource)
        )
    }

    private func candidate(
        source: String = "claude-code",
        lastActivityNs: Int64? = nil,
        isLive: Bool = false,
        isFavorite: Bool = false,
        generationMatchesCapture: Bool = true,
        verifiedReceiptReplicaIDs: Set<String> = ["hq", "m1"],
        hasNewerCapture: Bool = false,
        hasActiveOperation: Bool = false,
        sourceByteCount: Int64 = 1_024
    ) -> ArchiveReclamationCandidate {
        ArchiveReclamationCandidate(
            source: source,
            lastActivityNs: lastActivityNs ?? now - 180 * day,
            isLive: isLive,
            isFavorite: isFavorite,
            generationMatchesCapture: generationMatchesCapture,
            verifiedReceiptReplicaIDs: verifiedReceiptReplicaIDs,
            hasNewerCapture: hasNewerCapture,
            hasActiveOperation: hasActiveOperation,
            sourceByteCount: sourceByteCount
        )
    }

    private func context(
        enabled: Bool = true,
        hotWindowDays: Int = 30,
        recoveryLeaseVerifiedAtNs: [String: Int64]? = nil
    ) -> ArchiveReclamationContext {
        ArchiveReclamationContext(
            enabled: enabled,
            hotWindowDays: hotWindowDays,
            nowNs: now,
            recoveryLeaseVerifiedAtNs: recoveryLeaseVerifiedAtNs ?? ["hq": now, "m1": now]
        )
    }
}

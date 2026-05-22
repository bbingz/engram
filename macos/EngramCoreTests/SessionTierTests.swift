import XCTest
@testable import EngramCoreRead

/// Focused coverage for the probe / noise tiering rules ported from the
/// TypeScript reference (session-tier.ts) for Swift↔TS parity (round-7 SST-5).
/// Prior to this, the only Swift SessionTier coverage was a handful of cases in
/// IndexerParityTests; the probe-first-line and extended noise patterns had none.
final class SessionTierTests: XCTestCase {
    func testProbeFirstLineWithFewMessagesIsLite() {
        for probe in ["ping", "PING", "  hello ", "say hello", "reply: t4"] {
            XCTAssertEqual(
                SessionTier.compute(TierInput(messageCount: 3, summary: probe)),
                .lite,
                "probe summary '\(probe)' with <=3 messages should be lite"
            )
        }
    }

    func testProbeFirstLineWithManyMessagesIsNotLite() {
        // The probe rule only applies at messageCount <= 3.
        XCTAssertEqual(
            SessionTier.compute(TierInput(messageCount: 5, summary: "ping")),
            .normal
        )
    }

    func testNonProbeShortSessionIsNormal() {
        XCTAssertEqual(
            SessionTier.compute(TierInput(messageCount: 3, summary: "fix the auth bug")),
            .normal
        )
    }

    func testExtendedNoisePatternsAreLite() {
        for noise in [
            "/usage",
            "Generate a short, clear title for this",
            "Reply exactly: DONE",
            "Reply with exactly: yes",
            "please reply with just the number",
            "/status/exit now",
        ] {
            XCTAssertEqual(
                SessionTier.compute(TierInput(messageCount: 5, summary: noise)),
                .lite,
                "noise summary '\(noise)' should be lite"
            )
        }
    }

    func testOrdinarySessionStaysNormal() {
        XCTAssertEqual(
            SessionTier.compute(TierInput(messageCount: 5, summary: "refactor the indexer")),
            .normal
        )
    }
}

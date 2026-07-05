import XCTest
@testable import Engram

@MainActor
final class EngramServiceStatusStoreTests: XCTestCase {
    func testDisplayStringAndRunningSemanticsMatchLegacyIndexerStatus() {
        let store = EngramServiceStatusStore()

        XCTAssertEqual(store.displayString, String(localized: "Stopped"))
        XCTAssertFalse(store.isRunning)

        store.status = .starting
        XCTAssertEqual(store.displayString, String(localized: "Starting..."))
        XCTAssertFalse(store.isRunning)

        let totalSessions = 42
        store.status = .running(total: totalSessions, todayParents: 5)
        XCTAssertEqual(
            store.displayString,
            String.localizedStringWithFormat(String(localized: "%lld sessions indexed"), totalSessions)
        )
        XCTAssertTrue(store.isRunning)

        let errorMessage = "fail"
        store.status = .error(message: errorMessage)
        XCTAssertEqual(
            store.displayString,
            String.localizedStringWithFormat(String(localized: "Error: %@"), errorMessage)
        )
        XCTAssertFalse(store.isRunning)
    }

    func testAppliesReadyIndexedAndSummaryEvents() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode(#"{"event":"ready","indexed":150,"total":200,"todayParents":11}"#))
        XCTAssertEqual(store.totalSessions, 200)
        XCTAssertEqual(store.todayParentSessions, 11)
        XCTAssertEqual(store.status, .running(total: 200, todayParents: 11))
        XCTAssertNotNil(store.lastEventAt)

        store.apply(try decode(#"{"event":"watcher_indexed","total":202,"todayParents":12}"#))
        XCTAssertEqual(store.totalSessions, 202)
        XCTAssertEqual(store.todayParentSessions, 12)

        store.apply(try decode(#"{"event":"summary_generated","sessionId":"sess-123","summary":"Built a feature","total":203,"todayParents":13}"#))
        XCTAssertEqual(store.lastSummarySessionId, "sess-123")
        XCTAssertEqual(store.totalSessions, 203)
        XCTAssertEqual(store.todayParentSessions, 13)
    }

    func testAppliesErrorAndDegradedEvents() throws {
        let store = EngramServiceStatusStore()

        let warningMessage = "slow provider"
        store.apply(try decode(#"{"event":"warning","message":"slow provider"}"#))
        XCTAssertEqual(store.status, .degraded(message: warningMessage))
        XCTAssertEqual(
            store.displayString,
            String.localizedStringWithFormat(String(localized: "Degraded: %@"), warningMessage)
        )

        let errorMessage = "Something went wrong"
        store.apply(try decode(#"{"event":"error","message":"Something went wrong"}"#))
        XCTAssertEqual(store.status, .error(message: errorMessage))
        XCTAssertEqual(
            store.displayString,
            String.localizedStringWithFormat(String(localized: "Error: %@"), errorMessage)
        )
    }

    func testIgnoresLegacyWebStatusEventsFromOlderServiceBinary() throws {
        let store = EngramServiceStatusStore()
        store.apply(try decode(#"{"event":"ready","total":12,"todayParents":3}"#))

        let baselineStatus = store.status
        let baselineTotal = store.totalSessions
        let baselineToday = store.todayParentSessions

        store.apply(try decode(#"{"event":"web_ready","host":"127.0.0.1","port":3457}"#))
        XCTAssertEqual(store.status, baselineStatus)
        XCTAssertEqual(store.totalSessions, baselineTotal)
        XCTAssertEqual(store.todayParentSessions, baselineToday)

        store.apply(try decode(#"{"event":"web_error","message":"legacy web startup failed"}"#))
        XCTAssertEqual(store.status, baselineStatus)
        XCTAssertEqual(store.totalSessions, baselineTotal)
        XCTAssertEqual(store.todayParentSessions, baselineToday)
    }

    func testDecodesLegacyUsageDataAlias() throws {
        let event = try decode("""
        {
          "event": "usage",
          "data": [
            {"source":"openai","metric":"requests","value":40,"limit":100,"resetAt":"2026-04-24T00:00:00Z","status":"ok"}
          ]
        }
        """)
        let store = EngramServiceStatusStore()

        store.apply(event)

        XCTAssertEqual(store.usageData.count, 1)
        XCTAssertEqual(store.usageData[0].source, "openai")
        XCTAssertEqual(store.usageData[0].metric, "requests")
        XCTAssertEqual(store.usageData[0].value, 40)
        XCTAssertEqual(store.usageData[0].limit, 100)
        XCTAssertEqual(store.usageData[0].resetAt, "2026-04-24T00:00:00Z")
        XCTAssertEqual(store.usageData[0].status, "ok")
    }

    func testUsagePressureSummaryPrefersCriticalUsage() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"codex","metric":"5h window used","value":72,"unit":"%","resetAt":"2026-06-07T10:00:00Z","status":"attention"},
            {"source":"claude-code","metric":"weekly remaining","value":4,"unit":"%","resetAt":"2026-06-08T00:00:00Z","status":"critical"}
          ]
        }
        """))

        XCTAssertEqual(store.usagePressureSummary?.severity, .critical)
        XCTAssertEqual(
            store.usagePressureSummary?.message,
            "Usage critical: Claude Code weekly remaining 4% (96% used) · resets 2026-06-08 00:00 UTC"
        )
    }

    func testUsagePressureSummaryClarifiesLegacyRemainingPercentWithoutUnit() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"claude-code","metric":"weekly remaining","value":4,"resetAt":"2026-06-08T00:00:00Z","status":"critical"}
          ]
        }
        """))

        XCTAssertEqual(
            store.usagePressureSummary?.message,
            "Usage critical: Claude Code weekly remaining 4% (96% used) · resets 2026-06-08 00:00 UTC"
        )
    }

    func testUsagePressureSummaryNormalizesStatusCaseAndWhitespace() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"claude-code","metric":"weekly remaining","value":4,"unit":"%","resetAt":"2026-06-08T00:00:00Z","status":" Critical "}
          ]
        }
        """))

        XCTAssertEqual(store.usagePressureSummary?.severity, .critical)
        XCTAssertEqual(
            store.usagePressureSummary?.message,
            "Usage critical: Claude Code weekly remaining 4% (96% used) · resets 2026-06-08 00:00 UTC"
        )
    }

    func testUsagePressureSummaryNormalizesSourceLabelCaseAndWhitespace() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":" CODEX ","metric":"5h token pressure","value":92,"unit":"%","limit":100,"resetAt":"2026-06-07T10:00:00Z","status":"critical"}
          ]
        }
        """))

        XCTAssertEqual(
            store.usagePressureSummary?.message,
            "Usage critical: Codex 5h token pressure 92.0/100.0% · resets 2026-06-07 10:00 UTC"
        )
    }

    func testUsagePressureSummaryPreservesExplicitLimit() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"codex","metric":"weekly token pressure","value":91,"unit":"%","limit":100,"resetAt":"2026-06-08T00:00:00Z","status":"critical"}
          ]
        }
        """))

        XCTAssertEqual(store.usagePressureSummary?.severity, .critical)
        XCTAssertEqual(
            store.usagePressureSummary?.message,
            "Usage critical: Codex weekly token pressure 91.0/100.0% · resets 2026-06-08 00:00 UTC"
        )
    }

    func testUsagePressureSummaryIdentityIsStableAcrossDisplayMessageChanges() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":" Codex ","metric":"5H TOKEN PRESSURE","value":78,"unit":"%","limit":100,"resetAt":"2026-06-07T10:00:00Z","status":"attention"}
          ]
        }
        """))
        let first = store.usagePressureSummary

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"codex","metric":"5h token pressure","value":78,"unit":"%","limit":100,"resetAt":"2026-06-07T11:00:00Z","status":"attention"}
          ]
        }
        """))

        XCTAssertEqual(first?.identity, "codex:5h token pressure")
        XCTAssertEqual(store.usagePressureSummary?.identity, first?.identity)
        XCTAssertNotEqual(store.usagePressureSummary?.message, first?.message)
    }

    func testUsagePressureSummaryPrefersWorstPressureWithinSameSeverity() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"codex","metric":"weekly token pressure","value":78,"unit":"%","limit":100,"resetAt":"2026-06-08T00:00:00Z","status":"attention"},
            {"source":"opencode","metric":"5h token pressure","value":92,"unit":"%","limit":100,"resetAt":"2026-06-07T10:00:00Z","status":"attention"}
          ]
        }
        """))

        XCTAssertEqual(store.usagePressureSummary?.severity, .attention)
        XCTAssertEqual(
            store.usagePressureSummary?.message,
            "Usage attention: OpenCode 5h token pressure 92.0/100.0% · resets 2026-06-07 10:00 UTC"
        )
    }

    func testUsagePressureSummaryIgnoresObservedUsage() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"claude-code","metric":"7d token total","value":993395073,"unit":"tokens","status":"observed"}
          ]
        }
        """))

        XCTAssertNil(store.usagePressureSummary)
    }

    func testAppliesRefreshUsageResponsePressureImmediately() throws {
        let store = EngramServiceStatusStore()

        store.apply(EngramServiceRefreshUsageResponse(
            snapshotCount: 8,
            sources: ["codex", "opencode"],
            pressure: [
                EngramServiceUsageItem(
                    source: "codex",
                    metric: "5h token pressure",
                    value: 92,
                    unit: "%",
                    limit: 100,
                    resetAt: "2026-06-07T10:00:00Z",
                    status: "critical"
                )
            ]
        ))

        XCTAssertEqual(store.usageData.map(\.source), ["codex"])
        XCTAssertEqual(store.usagePressureSummary?.severity, .critical)
        XCTAssertEqual(
            store.usagePressureSummary?.message,
            "Usage critical: Codex 5h token pressure 92.0/100.0% · resets 2026-06-07 10:00 UTC"
        )
        XCTAssertNotNil(store.lastEventAt)
    }

    func testRefreshUsageResponseReplacesOnlyRefreshedSourcePressure() throws {
        let store = EngramServiceStatusStore()

        store.apply(try decode("""
        {
          "event": "usage",
          "usage": [
            {"source":"codex","metric":"5h token pressure","value":92,"unit":"%","limit":100,"resetAt":"2026-06-07T10:00:00Z","status":"critical"},
            {"source":"opencode","metric":"weekly token pressure","value":88,"unit":"%","limit":100,"resetAt":"2026-06-08T00:00:00Z","status":"attention"},
            {"source":"codex","metric":"7d token total","value":1200,"unit":"tokens","status":"observed"}
          ]
        }
        """))

        store.apply(EngramServiceRefreshUsageResponse(
            snapshotCount: 3,
            sources: [" CODEX "],
            pressure: [
                EngramServiceUsageItem(
                    source: "codex",
                    metric: "5h token pressure",
                    value: 72,
                    unit: "%",
                    limit: 100,
                    resetAt: "2026-06-07T11:00:00Z",
                    status: "attention"
                )
            ]
        ))

        XCTAssertEqual(
            store.usageData.map { "\($0.source):\($0.metric):\($0.value)" },
            [
                "opencode:weekly token pressure:88.0",
                "codex:7d token total:1200.0",
                "codex:5h token pressure:72.0",
            ]
        )
    }

    private func decode(_ json: String) throws -> EngramServiceEvent {
        try JSONDecoder().decode(EngramServiceEvent.self, from: Data(json.utf8))
    }
}

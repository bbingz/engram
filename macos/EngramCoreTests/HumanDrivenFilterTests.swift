import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

/// Verifies the shared human-driven visibility predicate selects exactly the
/// sessions a human drove, against a real migrated schema.
final class HumanDrivenFilterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-humandriven-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func insert(
        _ writer: EngramDatabaseWriter,
        id: String,
        source: String = "claude-code",
        agentRole: String?,
        instructionCount: Int?,
        humanTurnCount: Int?,
        userMessageCount: Int = 0,
        tier: String
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO sessions
                  (id, source, start_time, cwd, file_path, agent_role, instruction_count, human_turn_count, user_message_count, tier)
                VALUES (?, ?, '2026-06-01T00:00:00.000Z', '/tmp', ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, source, "/tmp/\(id).jsonl", agentRole, instructionCount, humanTurnCount, userMessageCount, tier]
            )
        }
    }

    private func expectedReliableSources(prefix: String = "") -> String {
        let quoted = HumanDrivenFilter.instructionSignalSources
            .map { "'\($0)'" }
            .joined(separator: ", ")
        return "\(prefix)source NOT IN (\(quoted))"
    }

    func testPredicateSelectsHumanDrivenSet() throws {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("f.sqlite").path)
        try writer.migrate()

        try insert(writer, id: "multi", agentRole: nil, instructionCount: 4, humanTurnCount: 4, tier: "normal")        // in: >=2 asks
        try insert(writer, id: "single", agentRole: nil, instructionCount: 1, humanTurnCount: 3, tier: "normal")       // out: 1 ask
        try insert(writer, id: "longthread", agentRole: nil, instructionCount: 1, humanTurnCount: 13, tier: "normal")  // in: >=12 turns
        try insert(writer, id: "premium1", agentRole: nil, instructionCount: 1, humanTurnCount: 2, tier: "premium")    // in: premium
        try insert(writer, id: "legacy-short", agentRole: nil, instructionCount: nil, humanTurnCount: nil, userMessageCount: 3, tier: "normal") // out: reliable NULL
        try insert(writer, id: "legacy-long", agentRole: nil, instructionCount: nil, humanTurnCount: nil, userMessageCount: 13, tier: "normal")  // in: legacy turn rescue
        try insert(writer, id: "legacy-other-source", source: "gemini-cli", agentRole: nil, instructionCount: nil, humanTurnCount: nil, tier: "normal") // in: source not yet extracted
        try insert(writer, id: "agent", agentRole: "dispatched", instructionCount: 5, humanTurnCount: 20, tier: "normal") // out: agent_role

        let visible = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE \(HumanDrivenFilter.sqlPredicate)")
        }
        XCTAssertEqual(Set(visible), ["multi", "longthread", "premium1", "legacy-long", "legacy-other-source"])
        XCTAssertFalse(visible.contains("single"))
        XCTAssertFalse(visible.contains("legacy-short"))
        XCTAssertFalse(visible.contains("agent"))
    }

    func testPredicateEncodesThresholds() {
        let predicate = HumanDrivenFilter.sqlPredicate
        XCTAssertTrue(predicate.hasPrefix("("))
        XCTAssertTrue(predicate.hasSuffix(")"))
        XCTAssertTrue(predicate.contains("agent_role IS NULL"))
        XCTAssertTrue(predicate.contains(expectedReliableSources()))
        XCTAssertTrue(predicate.contains("instruction_count >= \(HumanDrivenFilter.minInstructions)"))
        XCTAssertTrue(predicate.contains("human_turn_count >= \(HumanDrivenFilter.minHumanTurns)"))
        XCTAssertTrue(predicate.contains("user_message_count >= \(HumanDrivenFilter.minHumanTurns)"))
        XCTAssertTrue(predicate.contains("tier = 'premium'"))
    }

    func testQualifiedPredicatePrefixesColumnsWithoutStringReplacement() {
        let predicate = HumanDrivenFilter.sqlPredicate(alias: "s")
        XCTAssertTrue(predicate.hasPrefix("("))
        XCTAssertTrue(predicate.hasSuffix(")"))
        XCTAssertTrue(predicate.contains("s.agent_role IS NULL"))
        XCTAssertTrue(predicate.contains(expectedReliableSources(prefix: "s.")))
        XCTAssertTrue(predicate.contains("s.instruction_count >= \(HumanDrivenFilter.minInstructions)"))
        XCTAssertTrue(predicate.contains("s.human_turn_count >= \(HumanDrivenFilter.minHumanTurns)"))
        XCTAssertTrue(predicate.contains("s.user_message_count >= \(HumanDrivenFilter.minHumanTurns)"))
        XCTAssertTrue(predicate.contains("s.tier = 'premium'"))
        XCTAssertFalse(predicate.contains("s.s."))
    }
}

import XCTest
import GRDB
@testable import EngramServiceCore

final class ObservabilityRetentionTests: XCTestCase {
    private func tmpPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-retention-\(UUID().uuidString).sqlite").path
    }

    private func makeSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE metrics (id INTEGER PRIMARY KEY, name TEXT, type TEXT, value REAL, tags TEXT, ts TEXT NOT NULL);
            CREATE TABLE traces (id INTEGER PRIMARY KEY, trace_id TEXT, span_id TEXT, name TEXT, module TEXT, start_ts TEXT NOT NULL, source TEXT);
            CREATE TABLE ai_audit_log (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, caller TEXT, operation TEXT);
            CREATE TABLE logs (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, level TEXT, module TEXT, message TEXT, source TEXT);
        """)
    }

    func testPrunesOldKeepsRecentAndCounts() throws {
        let queue = try DatabaseQueue(path: tmpPath())
        let now = Date()
        let f = ISO8601DateFormatter()
        let oldZ = f.string(from: now.addingTimeInterval(-100 * 86_400))   // has Z
        let recentZ = f.string(from: now.addingTimeInterval(-1 * 86_400))  // has Z
        // ai_audit_log stores timestamps without a trailing Z in production;
        // exercise that form to guard the lexical-compare-across-formats claim.
        let oldNoZ = String(oldZ.dropLast())
        let recentNoZ = String(recentZ.dropLast())

        try queue.write { db in
            try self.makeSchema(db)
            try db.execute(sql: "INSERT INTO metrics (name,type,value,tags,ts) VALUES ('m','counter',1,NULL,?),('m','counter',1,NULL,?)", arguments: [oldZ, recentZ])
            try db.execute(sql: "INSERT INTO traces (trace_id,span_id,name,module,start_ts,source) VALUES ('t','a','n','m',?,'daemon'),('t','b','n','m',?,'daemon')", arguments: [oldZ, recentZ])
            try db.execute(sql: "INSERT INTO ai_audit_log (ts,caller,operation) VALUES (?,'c','o'),(?,'c','o')", arguments: [oldNoZ, recentNoZ])
            try db.execute(sql: "INSERT INTO logs (ts,level,module,message,source) VALUES (?,'info','m','x','daemon'),(?,'info','m','x','daemon')", arguments: [oldZ, recentZ])
        }

        let deleted = try queue.write { db in
            try ObservabilityRetention.prune(db, now: now)
        }
        XCTAssertEqual(deleted, 4, "one old row per table")

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metrics"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM traces"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_audit_log"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logs"), 1)
        }
    }
}

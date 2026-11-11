import Darwin
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class WebFleetSnapshotTests: XCTestCase {
    private func machine() -> [String: Any] {
        ["id": "hq", "label": "HQ", "role": "index", "status": "ok", "observedAt": 100,
         "lastAttemptAt": 100, "processes": [], "storage": [], "roots": [], "replicas": [], "errors": []]
    }
    private func bytes(_ machines: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "generatedAt": 100, "machines": machines])
    }
    private func decode(_ machines: [[String: Any]]) throws {
        let snapshot = try JSONDecoder().decode(WebFleetRoutes.Snapshot.self, from: bytes(machines))
        try WebFleetRoutes.validate(snapshot)
    }

    func testUnknownMetricsAndOldObservationsRemainUnknownInsteadOfZero() throws {
        var m = machine()
        m["observedAt"] = 1
        let snapshot = try JSONDecoder().decode(WebFleetRoutes.Snapshot.self, from: bytes([m]))
        try WebFleetRoutes.validate(snapshot)
        XCTAssertNil(snapshot.machines[0].capture)
        XCTAssertNil(snapshot.machines[0].disk)
        XCTAssertNil(snapshot.machines[0].machineId)
        XCTAssertEqual(snapshot.machines[0].observedAt, 1, "staleness must remain visible to the browser")
    }

    func testRejectsDuplicateMachinesInvalidStatesAndImpossibleDiskCounts() throws {
        XCTAssertThrowsError(try decode([machine(), machine()]))
        for (key, value) in [("status", "healthy"), ("role", "admin")] {
            var m = machine(); m[key] = value
            XCTAssertThrowsError(try decode([m]))
        }
        var m = machine(); m["disk"] = ["totalBytes": 100, "freeBytes": 101]
        XCTAssertThrowsError(try decode([m]))
        m = machine(); m["disk"] = ["totalBytes": 100, "freeBytes": -1]
        XCTAssertThrowsError(try decode([m]))
        m = machine(); m["observedAt"] = NSNull()
        XCTAssertThrowsError(try decode([m]))
        m = machine(); m["status"] = "unreachable"
        XCTAssertThrowsError(try decode([m]), "failed probe cannot carry a fresh-looking old observation")
    }

    func testRejectsUnsafeNumericRangesAndSourceCounts() throws {
        var m = machine()
        m["capture"] = ["publications": 1, "capturedLocators": 1, "dirtyLocators": 0,
                        "coolingLocators": 1, "unavailableLocators": 0]
        XCTAssertThrowsError(try decode([m]))
        m = machine(); m["lastAttemptAt"] = Int64.max
        XCTAssertThrowsError(try decode([m]))
        m = machine(); m["errors"] = ["raw-secret-path"]
        XCTAssertThrowsError(try decode([m]))
    }

    func testReaderRequiresPrivateRegularFileAndProjectsOnlyKnownFields() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("fleet-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        try bytes([machine()]).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(try WebFleetRoutes.read(path: file.path).machines.count, 1)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try WebFleetRoutes.read(path: file.path))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let alias = directory.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: file.path)
        XCTAssertThrowsError(try WebFleetRoutes.read(path: alias.path))
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        XCTAssertThrowsError(try WebFleetRoutes.read(path: file.path))
        XCTAssertThrowsError(try WebFleetRoutes.read(path: nil))
    }
}

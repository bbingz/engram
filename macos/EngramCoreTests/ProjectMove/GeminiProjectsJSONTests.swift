// macos/EngramCoreTests/ProjectMove/GeminiProjectsJSONTests.swift
// Mirrors tests/core/project-move/gemini-projects-json.test.ts (Node parity baseline).
import Foundation
import XCTest
@testable import EngramCoreWrite

final class GeminiProjectsJSONTests: XCTestCase {
    private var tmpRoot: URL!
    private var file: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-gemini-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        file = tmpRoot.appendingPathComponent("projects.json")
    }

    override func tearDownWithError() throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - plan

    func testPlanCapturesOldEntryAndSnapshotWhenWrappedFileMatches() throws {
        try writeJson(["projects": ["/a/proj": "proj", "/b/other": "other"]])
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        XCTAssertEqual(plan.oldEntry, GeminiProjectsEntry(cwd: "/a/proj", name: "proj"))
        XCTAssertEqual(plan.newEntry, GeminiProjectsEntry(cwd: "/a/proj-v2", name: "proj-v2"))
        XCTAssertNotNil(plan.originalText)
    }

    func testPlanHandlesMissingFile() throws {
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        XCTAssertNil(plan.oldEntry)
        XCTAssertEqual(plan.newEntry.name, "proj-v2")
        XCTAssertNil(plan.originalText)
    }

    func testPlanHandlesLegacyFlatLayout() throws {
        try writeJson(["/a/proj": "proj", "/b/other": "other"])
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        XCTAssertEqual(plan.oldEntry, GeminiProjectsEntry(cwd: "/a/proj", name: "proj"))
    }

    func testPlanReturnsNilOldEntryWhenCwdMissingFromMap() throws {
        try writeJson(["projects": ["/b/other": "other"]])
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        XCTAssertNil(plan.oldEntry)
        XCTAssertEqual(plan.newEntry, GeminiProjectsEntry(cwd: "/a/proj-v2", name: "proj-v2"))
    }

    func testPlanThrowsOnInvalidJson() throws {
        try "{invalid".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try GeminiProjectsJSON.plan(
                filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
            )
        ) { err in
            guard case GeminiProjectsJSONError.invalidJson(_, let message) = err else {
                return XCTFail("expected invalidJson, got \(err)")
            }
            XCTAssertTrue(message.contains("not valid JSON"))
        }
    }

    // MARK: - apply

    func testApplyReplacesMatchingEntryAtomically() throws {
        try writeJson(["projects": ["/a/proj": "proj", "/b/other": "other"]])
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        try GeminiProjectsJSON.apply(plan: plan)

        let after = try readMap()
        XCTAssertNotNil(after["projects"])
        let projects = after["projects"] as? [String: String] ?? [:]
        XCTAssertNil(projects["/a/proj"])
        XCTAssertEqual(projects["/a/proj-v2"], "proj-v2")
        XCTAssertEqual(projects["/b/other"], "other")
    }

    func testApplyPreservesLegacyFlatLayout() throws {
        try writeJson(["/a/proj": "proj"])
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        try GeminiProjectsJSON.apply(plan: plan)

        let after = try readMap()
        // Legacy: no `projects` wrapper at top level.
        XCTAssertNil(after["projects"])
        XCTAssertEqual(after["/a/proj-v2"] as? String, "proj-v2")
        XCTAssertNil(after["/a/proj"])
    }

    func testApplyCreatesFileWhenMissing() throws {
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        try GeminiProjectsJSON.apply(plan: plan)
        let after = try readMap()
        let projects = after["projects"] as? [String: String] ?? [:]
        XCTAssertEqual(projects["/a/proj-v2"], "proj-v2")
    }

    // MARK: - reverse

    func testReverseRestoresSnapshotByteForByte() throws {
        let originalJson = """
        {
          "projects": {
            "/a/proj": "proj",
            "/b/other": "other"
          }
        }
        """
        try originalJson.write(to: file, atomically: true, encoding: .utf8)

        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        try GeminiProjectsJSON.apply(plan: plan)
        XCTAssertNotEqual(
            try String(contentsOf: file, encoding: .utf8),
            originalJson,
            "apply should have changed the file"
        )

        try GeminiProjectsJSON.reverse(plan: plan)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            originalJson,
            "reverse must restore the captured snapshot byte-for-byte"
        )
    }

    func testReverseUnlinksFileWhenEngramCreatedAndMapEmptiesOut() throws {
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        try GeminiProjectsJSON.apply(plan: plan)
        try GeminiProjectsJSON.reverse(plan: plan)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "file engram created should be unlinked when reversal empties it"
        )
    }

    // MARK: - collectOtherCwdsSharingBasename

    func testFlagsOtherCwdsSharingBasename() throws {
        try writeJson([
            "projects": [
                "/a/proj": "proj",
                "/b/proj": "proj",
                "/c/unrelated": "unrelated",
            ],
        ])
        let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingBasename(
            filePath: file.path,
            targetBasename: "proj",
            srcCwd: "/a/proj"
        )
        XCTAssertEqual(conflicts, ["/b/proj"])
    }

    func testReturnsEmptyWhenNoConflict() throws {
        try writeJson(["projects": ["/a/proj": "proj", "/b/other": "other"]])
        let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingBasename(
            filePath: file.path, targetBasename: "proj", srcCwd: "/a/proj"
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testTreatsMissingFileAsEmptyConflicts() throws {
        let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingBasename(
            filePath: file.path, targetBasename: "proj", srcCwd: "/a/proj"
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - helpers

    private func writeJson(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: file)
    }

    private func readMap() throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

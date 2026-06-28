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
        XCTAssertEqual(
            plan.newEntry,
            GeminiProjectsEntry(
                cwd: "/a/proj-v2",
                name: "a6170e3f8a116ca9f104bb61bcb6b32eb2c200ad23eb97afa32e229e5970d417"
            )
        )
        XCTAssertNotNil(plan.originalText)
    }

    func testPlanHandlesMissingFile() throws {
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        XCTAssertNil(plan.oldEntry)
        XCTAssertEqual(
            plan.newEntry.name,
            "a6170e3f8a116ca9f104bb61bcb6b32eb2c200ad23eb97afa32e229e5970d417"
        )
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
        XCTAssertEqual(
            plan.newEntry,
            GeminiProjectsEntry(
                cwd: "/a/proj-v2",
                name: "a6170e3f8a116ca9f104bb61bcb6b32eb2c200ad23eb97afa32e229e5970d417"
            )
        )
    }

    func testPlanUsesGeminiHashForNewEntryName() throws {
        // newEntry.name must match Gemini CLI's SHA-256 project directory so
        // projects.json stays consistent with the renamed ~/.gemini/tmp/<hash>/ dir.
        try writeJson(["projects": ["/a/old": "old"]])
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/old", newCwd: "/Users/bing/-Code-/WebSite_Gemini"
        )
        XCTAssertEqual(
            plan.newEntry.name,
            "14c0b06be029ed0eec4a9c32d825e06252ec7b3893898df56a8891dba6fdebf2"
        )
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
        XCTAssertEqual(
            projects["/a/proj-v2"],
            "a6170e3f8a116ca9f104bb61bcb6b32eb2c200ad23eb97afa32e229e5970d417"
        )
        XCTAssertEqual(projects["/b/other"], "other")
    }

    func testAtomicWriterCreatesTempWithPermissionsAtCreation() throws {
        let source = try projectSource("EngramCoreWrite/ProjectMove/GeminiProjectsJSON.swift")

        XCTAssertFalse(source.contains("try content.write(toFile: tmp"))
        XCTAssertTrue(source.contains("attributes: [.posixPermissions:"))
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
        XCTAssertEqual(
            after["/a/proj-v2"] as? String,
            "a6170e3f8a116ca9f104bb61bcb6b32eb2c200ad23eb97afa32e229e5970d417"
        )
        XCTAssertNil(after["/a/proj"])
    }

    func testApplyCreatesFileWhenMissing() throws {
        let plan = try GeminiProjectsJSON.plan(
            filePath: file.path, oldCwd: "/a/proj", newCwd: "/a/proj-v2"
        )
        try GeminiProjectsJSON.apply(plan: plan)
        let after = try readMap()
        let projects = after["projects"] as? [String: String] ?? [:]
        XCTAssertEqual(
            projects["/a/proj-v2"],
            "a6170e3f8a116ca9f104bb61bcb6b32eb2c200ad23eb97afa32e229e5970d417"
        )
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

    // MARK: - collectOtherCwdsSharingProjectName

    func testFlagsOtherCwdsSharingProjectName() throws {
        try writeJson([
            "projects": [
                "/a/proj": "proj",
                "/b/proj": "proj",
                "/c/unrelated": "unrelated",
            ],
        ])
        let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingProjectName(
            filePath: file.path,
            targetProjectName: "proj",
            srcCwd: "/a/proj"
        )
        XCTAssertEqual(conflicts, ["/b/proj"])
    }

    func testReturnsEmptyWhenNoConflict() throws {
        try writeJson(["projects": ["/a/proj": "proj", "/b/other": "other"]])
        let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingProjectName(
            filePath: file.path, targetProjectName: "proj", srcCwd: "/a/proj"
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testTreatsMissingFileAsEmptyConflicts() throws {
        let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingProjectName(
            filePath: file.path, targetProjectName: "proj", srcCwd: "/a/proj"
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

    private func projectSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

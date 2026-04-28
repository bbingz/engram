// macos/EngramCoreTests/ProjectMove/BatchTests.swift
// Mirrors the parser + runner contract of tests/core/project-move/batch.test.ts.
// JSON-only payload (no YAML). Verifies schema validation, XOR, alias
// matching, ~ expansion, stopOnError vs collect-all, archive integration.
import Foundation
import XCTest
@testable import EngramCoreWrite

final class BatchTests: XCTestCase {
    private var tempRoot: URL!
    private var writer: EngramDatabaseWriter!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        dbURL = tempRoot.appendingPathComponent("index.sqlite")
        writer = try EngramDatabaseWriter(path: dbURL.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
    }

    // MARK: - parser

    func testParseRejectsMalformedJson() {
        let bytes = Data("{ not json".utf8)
        XCTAssertThrowsError(try Batch.parseJSON(bytes)) { err in
            guard case BatchError.malformedJson = err else {
                return XCTFail("expected malformedJson, got \(err)")
            }
        }
    }

    func testParseRejectsNonV1Schema() throws {
        let json = #"{"version":2,"operations":[]}"#
        XCTAssertThrowsError(try Batch.parseJSON(Data(json.utf8))) { err in
            guard case BatchError.unsupportedVersion(let v) = err else {
                return XCTFail("expected unsupportedVersion, got \(err)")
            }
            XCTAssertEqual(v, 2)
        }
    }

    func testParseRequiresOperationsList() {
        let json = #"{"version":1}"#
        XCTAssertThrowsError(try Batch.parseJSON(Data(json.utf8))) { err in
            guard case BatchError.operationsMissing = err else {
                return XCTFail("expected operationsMissing, got \(err)")
            }
        }
    }

    func testParseRejectsContinueFrom() {
        // continue_from is reserved in v1 but not yet executable. Silently
        // ignoring would risk re-running already-completed migrations.
        let json = #"{"version":1,"operations":[],"continue_from":"abc"}"#
        XCTAssertThrowsError(try Batch.parseJSON(Data(json.utf8))) { err in
            guard case BatchError.continueFromUnsupported = err else {
                return XCTFail("expected continueFromUnsupported, got \(err)")
            }
        }
    }

    func testParseRejectsOperationWithoutSrc() {
        let json = #"{"version":1,"operations":[{}]}"#
        XCTAssertThrowsError(try Batch.parseJSON(Data(json.utf8))) { err in
            guard case BatchError.operationInvalid(let idx, _) = err else {
                return XCTFail("expected operationInvalid, got \(err)")
            }
            XCTAssertEqual(idx, 0)
        }
    }

    func testParseEnforcesDstArchiveXOR() {
        // Both set
        let both = #"{"version":1,"operations":[{"src":"/a","dst":"/b","archive":true}]}"#
        XCTAssertThrowsError(try Batch.parseJSON(Data(both.utf8))) { err in
            guard case BatchError.operationInvalid(_, let reason) = err else {
                return XCTFail("expected operationInvalid for both-set, got \(err)")
            }
            XCTAssertTrue(reason.contains("exactly one"))
        }
        // Neither set
        let neither = #"{"version":1,"operations":[{"src":"/a"}]}"#
        XCTAssertThrowsError(try Batch.parseJSON(Data(neither.utf8))) { err in
            guard case BatchError.operationInvalid = err else {
                return XCTFail("expected operationInvalid for neither-set, got \(err)")
            }
        }
    }

    func testParseAcceptsBothArchiveToCasings() throws {
        let snake = #"{"version":1,"operations":[{"src":"/a","archive":true,"archive_to":"归档完成"}]}"#
        let camel = #"{"version":1,"operations":[{"src":"/a","archive":true,"archiveTo":"归档完成"}]}"#
        XCTAssertEqual(try Batch.parseJSON(Data(snake.utf8)).operations[0].archiveTo, "归档完成")
        XCTAssertEqual(try Batch.parseJSON(Data(camel.utf8)).operations[0].archiveTo, "归档完成")
    }

    func testParseAppliesDefaults() throws {
        let json = #"{"version":1,"operations":[{"src":"/a","dst":"/b"}]}"#
        let doc = try Batch.parseJSON(Data(json.utf8))
        XCTAssertTrue(doc.defaults.stopOnError, "default stop_on_error must be true")
        XCTAssertFalse(doc.defaults.dryRun)
    }

    func testParseRespectsSnakeAndCamelDefaults() throws {
        let snake = #"{"version":1,"defaults":{"stop_on_error":false,"dry_run":true},"operations":[{"src":"/a","dst":"/b"}]}"#
        let camel = #"{"version":1,"defaults":{"stopOnError":false,"dryRun":true},"operations":[{"src":"/a","dst":"/b"}]}"#
        XCTAssertEqual(try Batch.parseJSON(Data(snake.utf8)).defaults,
                       BatchDefaults(stopOnError: false, dryRun: true))
        XCTAssertEqual(try Batch.parseJSON(Data(camel.utf8)).defaults,
                       BatchDefaults(stopOnError: false, dryRun: true))
    }

    // MARK: - run integration

    func testRunStopsOnFirstFailureByDefault() async throws {
        let (firstSrc, _) = try makeProjectFixture(name: "first")
        let firstDst = tempRoot.appendingPathComponent("first-renamed").path
        // Second op points at a non-existent path → orchestrator throws (FsOps).
        let secondOp = BatchOperation(src: "/no/such/path/second", dst: "/also/missing")
        let firstOp = BatchOperation(src: firstSrc, dst: firstDst)
        let thirdOp = BatchOperation(src: "/never/run", dst: "/never/dst")

        let doc = BatchDocument(operations: [firstOp, secondOp, thirdOp])
        let result = await Batch.run(doc, writer: writer, overrides: makeOverrides())
        XCTAssertEqual(result.completed.count, 1)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped.first, thirdOp, "halt must skip the third op")
    }

    func testRunCollectsAllFailuresWhenStopOnErrorFalse() async throws {
        let (firstSrc, _) = try makeProjectFixture(name: "first")
        let (thirdSrc, _) = try makeProjectFixture(name: "third")
        let doc = BatchDocument(
            defaults: BatchDefaults(stopOnError: false, dryRun: false),
            operations: [
                BatchOperation(src: firstSrc, dst: tempRoot.appendingPathComponent("first-renamed").path),
                BatchOperation(src: "/no/such/missing", dst: "/also/missing"),
                BatchOperation(src: thirdSrc, dst: tempRoot.appendingPathComponent("third-renamed").path),
            ]
        )
        let result = await Batch.run(doc, writer: writer, overrides: makeOverrides())
        XCTAssertEqual(result.completed.count, 2, "must run first + third even after middle fails")
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testRunSurfacesArchiveSuggestionFailureAsBatchFailure() async throws {
        // Empty fixture is "ambiguous" only when content is non-empty + no
        // git; the empty rule actually catches this as 空项目. Instead, build
        // an ambiguous one (substantive content, no git).
        let src = try makeAmbiguousProject(name: "ambiguous")
        let doc = BatchDocument(operations: [
            BatchOperation(src: src, archive: true)
        ])
        let result = await Batch.run(doc, writer: writer, overrides: makeOverrides())
        XCTAssertEqual(result.completed.count, 0)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(result.failed[0].error.contains("auto-categorize") || result.failed[0].error.contains("Ambiguous") || result.failed[0].error.contains("ambig"),
                      "got error: \(result.failed[0].error)")
    }

    func testRunArchiveCreatesParentAndCommits() async throws {
        // Empty project → 空项目 bucket. Parent dir must be created automatically.
        let src = try makeProjectFixture(name: "empty-shell").src
        let doc = BatchDocument(operations: [
            BatchOperation(src: src, archive: true)
        ])
        let result = await Batch.run(doc, writer: writer, overrides: makeOverrides())
        XCTAssertEqual(result.completed.count, 1, "got failures: \(result.failed.map(\.error))")
        XCTAssertEqual(result.failed.count, 0)
        let archivedPath = result.completed[0]
        XCTAssertEqual(archivedPath.state, .committed)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archivedPath.renamedDirs.first?.newDir ?? archivedPath.migrationId)
            || FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("_archive/空项目/empty-shell").path),
            "expected archived dst on disk"
        )
    }

    func testTildeExpansionUsesOverrideHome() async throws {
        // When src is "~/proj" the override home should resolve it.
        // Set up <tempRoot>/proj as the project, src="~/proj"
        try _ = makeProjectFixture(name: "proj")
        // Move directly into tempRoot so the override home flows through.
        let homeRelativeSrc = "~/proj"
        let dst = tempRoot.appendingPathComponent("renamed").path
        let doc = BatchDocument(operations: [
            BatchOperation(src: homeRelativeSrc, dst: dst)
        ])
        let result = await Batch.run(doc, writer: writer, overrides: makeOverrides())
        XCTAssertEqual(result.completed.count, 1, "tilde must expand to override home; failures: \(result.failed.map(\.error))")
    }

    // MARK: - helpers

    @discardableResult
    private func makeProjectFixture(name: String) throws -> (src: String, ccDir: URL) {
        let projectDir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let gitDir = projectDir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main".write(
            to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )

        let encoded = ClaudeCodeProjectDir.encode(projectDir.path)
        let ccDir = tempRoot.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        try FileManager.default.createDirectory(at: ccDir, withIntermediateDirectories: true)
        return (projectDir.path, ccDir)
    }

    private func makeAmbiguousProject(name: String) throws -> String {
        // Substantive content, no .git, not empty → ambiguous category.
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "code".write(
            to: dir.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        return dir.path
    }

    private func makeOverrides() -> BatchOverrides {
        BatchOverrides(
            homeDirectory: tempRoot,
            lockPath: tempRoot.appendingPathComponent("project-move.lock").path,
            force: false
        )
    }
}

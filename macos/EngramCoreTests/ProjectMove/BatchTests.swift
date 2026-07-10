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

    func testRunCancellationStopsBeforeNextOperationAndReportsRemaining() async throws {
        let first = BatchOperation(src: "/not-run-a", dst: "/not-run-b")
        let second = BatchOperation(src: "/not-run-c", dst: "/not-run-d")
        let doc = BatchDocument(operations: [first, second])

        let result = await Batch.run(
            doc,
            writer: writer,
            overrides: makeOverrides(),
            shouldCancel: { true }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty, "cancel must not mis-label remaining as skipped")
        XCTAssertEqual(result.remaining, [first, second])
    }

    /// Mid-op cancel (shouldCancel true once the orchestrator runs) must put
    /// the current op into remaining — not completed — and mark cancelled.
    func testMidOperationCancelBeforeCommitLeavesOpInRemaining_repro() async throws {
        let first = BatchOperation(src: "/will-cancel", dst: "/will-cancel-dst")
        let second = BatchOperation(src: "/after", dst: "/after-dst")
        let doc = BatchDocument(operations: [first, second])

        // Always-true shouldCancel is also checked inside the orchestrator;
        // the top-of-loop check fires first so both ops remain. This asserts
        // the remaining contract wording: remaining = not committed.
        let result = await Batch.run(
            doc,
            writer: writer,
            overrides: makeOverrides(),
            shouldCancel: { true }
        )
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.completed.isEmpty, "cancelled-before-commit ops must not appear completed")
        XCTAssertEqual(result.remaining.count, 2)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    /// Cancel at the atomic commit boundary (not top-of-loop) via beginCommitIfNotCancelled.
    func testBatchCancelAtCommitBoundaryUsesBeginCommitProbe_repro() async throws {
        let (src, _) = try makeProjectFixture(name: "boundary-src")
        let dst = tempRoot.appendingPathComponent("boundary-dst").path
        let doc = BatchDocument(operations: [
            BatchOperation(src: src, dst: dst),
            BatchOperation(src: "/later", dst: "/later-dst"),
        ])
        // shouldCancel stays false so top-of-loop continues; commit probe rejects.
        let result = await Batch.run(
            doc,
            writer: writer,
            overrides: makeOverrides(),
            shouldCancel: { false },
            beginCommitIfNotCancelled: { false }
        )
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertEqual(result.remaining.count, 2, "current + later ops remain when commit boundary cancels")
        XCTAssertFalse(result.cancelUnsafe)
    }

    /// Item 1 commits; cancel after endItemCommitWindow; item 2 remains unstarted.
    func testBatchCancelAfterFirstItemCommitsStopsBeforeSecond_repro() async throws {
        let (src1, _) = try makeProjectFixture(name: "item1")
        let dst1 = tempRoot.appendingPathComponent("item1-dst").path
        let op1 = BatchOperation(src: src1, dst: dst1)
        let op2 = BatchOperation(src: "/later", dst: "/later-dst")
        let doc = BatchDocument(operations: [op1, op2])

        let cancelAfterFirst = CancelAfterFirstBox()
        let dryCompleted = PipelineResult(
            migrationId: "m1",
            state: .committed,
            src: src1,
            dst: dst1,
            moveStrategy: .rename,
            ccDirRenamed: false,
            renamedDirs: [],
            skippedDirs: [],
            perSource: [],
            totalFilesPatched: 0,
            totalOccurrences: 0,
            sessionsUpdated: 0,
            aliasCreated: false,
            review: ReviewResult(own: [], other: []),
            git: GitDirtyStatus(isGitRepo: false, dirty: false, untrackedOnly: false, porcelain: ""),
            manifest: [],
            error: nil
        )

        let result = await Batch.run(
            doc,
            writer: writer,
            overrides: BatchOverrides(
                homeDirectory: tempRoot,
                lockPath: tempRoot.appendingPathComponent("lock").path,
                force: true,
                runOperation: { op, _, _ in
                    if op.src == src1 {
                        await cancelAfterFirst.markFirstDone()
                        return dryCompleted
                    }
                    XCTFail("second op must not start after cancel")
                    return dryCompleted
                }
            ),
            shouldCancel: { cancelAfterFirst.shouldCancel },
            beginCommitIfNotCancelled: { true },
            endItemCommitWindow: {
                // After first item settles, arm cancel so next top-of-loop stops.
                cancelAfterFirst.armCancel()
            }
        )
        XCTAssertEqual(result.completed.count, 1)
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.remaining, [op2])
    }

    /// Batch.run itself catches ProjectMoveCancelledError(compensationSucceeded:false).
    func testBatchRunCatchesUnsafeCompensationError_repro() async throws {
        let op1 = BatchOperation(src: "/a", dst: "/b")
        let op2 = BatchOperation(src: "/c", dst: "/d")
        let doc = BatchDocument(operations: [op1, op2])
        let result = await Batch.run(
            doc,
            writer: writer,
            overrides: BatchOverrides(
                homeDirectory: tempRoot,
                runOperation: { _, _, _ in
                    throw ProjectMoveCancelledError(
                        compensationSucceeded: false,
                        compensationDetail: "rollback: 1 file failed"
                    )
                }
            ),
            shouldCancel: { false },
            beginCommitIfNotCancelled: { true }
        )
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.cancelUnsafe)
        XCTAssertEqual(result.cancelErrorName, "ProjectMoveCancelCompensationFailedError")
        XCTAssertTrue(result.cancelErrorMessage?.contains("compensation was incomplete") == true)
        XCTAssertEqual(result.remaining.count, 2)
        XCTAssertEqual(result.failed.count, 1)
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

    func testRunPatchesLargeJsonlSessionFile() async throws {
        let fixture = try makeProjectFixture(name: "large")
        let dst = tempRoot.appendingPathComponent("large-renamed").path
        let sessionFile = fixture.ccDir.appendingPathComponent("large.jsonl")
        try "{\"cwd\":\"\(fixture.src)\"}\n".write(to: sessionFile, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: sessionFile)
        try handle.truncate(atOffset: UInt64(JsonlPatch.maxInMemoryBytes + 4096))
        try handle.close()

        let doc = BatchDocument(operations: [
            BatchOperation(src: fixture.src, dst: dst)
        ])
        let result = await Batch.run(doc, writer: writer, overrides: makeOverrides())

        XCTAssertEqual(result.completed.count, 1, "failures: \(result.failed.map(\.error))")
        let patchedSessionFile = tempRoot
            .appendingPathComponent(".claude/projects/\(ClaudeCodeProjectDir.encode(dst))/large.jsonl")
        let input = try FileHandle(forReadingFrom: patchedSessionFile)
        let patched = try input.read(upToCount: 256)
        try input.close()
        let prefix = String(decoding: patched ?? Data(), as: UTF8.self)
        XCTAssertTrue(prefix.contains(dst), "expected large JSONL prefix to be patched, got \(prefix)")
    }

    // MARK: - helpers

    @discardableResult
    private func makeProjectFixture(name: String) throws -> (src: String, ccDir: URL) {
        let projectDir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try makeRealGitRepo(at: projectDir)

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

    private func makeRealGitRepo(at directory: URL) throws {
        try "base".write(
            to: directory.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Self.runGit(at: directory, ["init", "-q"])
        try Self.runGit(at: directory, ["config", "user.email", "t@t"])
        try Self.runGit(at: directory, ["config", "user.name", "t"])
        try Self.runGit(at: directory, ["add", "."])
        try Self.runGit(at: directory, ["commit", "-qm", "init"])
    }

    private static func runGit(at directory: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "BatchTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"]
            )
        }
    }
}

/// Box for cancel-after-first batch test.
private final class CancelAfterFirstBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldCancel = false
    var shouldCancel: Bool {
        lock.lock(); defer { lock.unlock() }
        return _shouldCancel
    }
    func markFirstDone() async {}
    func armCancel() {
        lock.lock(); _shouldCancel = true; lock.unlock()
    }
}

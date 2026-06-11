import Foundation
import Darwin
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

// Round-5 remediation coverage: adapter parser-output changes (Part B) plus the
// concurrency-safety fixes (Part A) that aren't already exercised by the shared
// adapter-parity goldens.
final class Round5RemediationTests: XCTestCase {
    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("round5-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(_ relativePath: String) throws -> String {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = macosRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        try data.write(to: url)
    }

    private func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            return String(data: data, encoding: .utf8)!
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testStartupVacuumUsesNonTransactionalWriterPath() throws {
        let writerSource = try source("EngramCoreWrite/Database/EngramDatabaseWriter.swift")
        XCTAssertTrue(writerSource.contains("func writeWithoutTransaction"))
        XCTAssertTrue(writerSource.contains("pool.writeWithoutTransaction"))

        let composition = try source("EngramCoreWrite/Indexing/StartupComposition.swift")
        let start = try XCTUnwrap(composition.range(of: "public func vacuumIfNeeded(_ fragmentationPercent: Int) throws -> Bool"))
        let end = try XCTUnwrap(composition.range(of: "public func reconcileInsights()", options: [], range: start.lowerBound..<composition.endIndex))
        let vacuum = String(composition[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(vacuum.contains("writer.writeWithoutTransaction"))
        XCTAssertFalse(vacuum.contains("writer.write {"))
    }

    func testStartupMaintenanceIsolatesVacuumFromReconcileSteps() throws {
        let source = try source("EngramCoreWrite/Indexing/StartupBackfills.swift")
        let start = try XCTUnwrap(source.range(of: "if try database.vacuumIfNeeded(15)"))
        let end = try XCTUnwrap(source.range(of: "do {\n            let pathsFixed", options: [], range: start.lowerBound..<source.endIndex))
        let maintenance = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(maintenance.contains(#"log.warn("db vacuum failed""#))
        XCTAssertTrue(maintenance.contains("let reconciled = try database.reconcileInsights()"))
        XCTAssertTrue(maintenance.contains(#"log.warn("db insight reconcile failed""#))
        XCTAssertTrue(maintenance.contains("let grouped = try database.reconcileGroupedSourceDirs()"))
        XCTAssertTrue(maintenance.contains(#"log.warn("db grouped source dir reconcile failed""#))
    }

    func testDeterministicFtsParserFailuresAreTerminal() throws {
        let source = try source("EngramCoreWrite/Indexing/IndexJobRunner.swift")
        let start = try XCTUnwrap(source.range(of: "private static func isTerminalFtsFailure"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - SQL helpers", options: [], range: start.lowerBound..<source.endIndex))
        let classifier = String(source[start.lowerBound..<end.lowerBound])

        let terminalBranchStart = try XCTUnwrap(classifier.range(of: "case .invalidUtf8"))
        let terminalBranchEnd = try XCTUnwrap(classifier.range(of: "return true", options: [], range: terminalBranchStart.lowerBound..<classifier.endIndex))
        let terminalBranch = String(classifier[terminalBranchStart.lowerBound..<terminalBranchEnd.upperBound])

        for failure in [".invalidUtf8", ".malformedJSON", ".messageLimitExceeded", ".lineTooLarge"] {
            XCTAssertTrue(terminalBranch.contains(failure), "\(failure) must stop retrying deterministic FTS failures")
        }

        let retryableStart = try XCTUnwrap(classifier.range(of: "case .truncatedJSON"))
        let retryableEnd = try XCTUnwrap(classifier.range(of: "return false", options: [], range: retryableStart.lowerBound..<classifier.endIndex))
        let retryableBranch = String(classifier[retryableStart.lowerBound..<retryableEnd.upperBound])
        XCTAssertFalse(retryableBranch.contains(".messageLimitExceeded"))
        XCTAssertFalse(retryableBranch.contains(".lineTooLarge"))
    }

    func testSnapshotWriterPrunesSupersededIndexJobsBeforeInsert() throws {
        let source = try source("EngramCoreWrite/Indexing/SessionSnapshotWriter.swift")
        let start = try XCTUnwrap(source.range(of: "private func insertIndexJobs"))
        let end = try XCTUnwrap(source.range(of: "private func shouldDeleteIndexArtifacts", options: [], range: start.lowerBound..<source.endIndex))
        let inserter = String(source[start.lowerBound..<end.lowerBound])

        let deleteRange = try XCTUnwrap(inserter.range(of: "DELETE FROM session_index_jobs"))
        let insertRange = try XCTUnwrap(inserter.range(of: "INSERT INTO session_index_jobs"))
        XCTAssertLessThan(deleteRange.lowerBound, insertRange.lowerBound)
        XCTAssertTrue(inserter.contains("let jobId ="))
        XCTAssertTrue(inserter.contains("WHERE session_id = ?"))
        XCTAssertTrue(inserter.contains("AND job_kind = ?"))
        XCTAssertTrue(inserter.contains("AND id != ?"))
        XCTAssertTrue(inserter.contains("status IN ('pending', 'failed_retryable', 'completed', 'not_applicable')"))
        XCTAssertTrue(inserter.contains("jobId,"))
    }

    func testSnapshotWriterRefreshesMovedLocalFilePath() throws {
        let source = try source("EngramCoreWrite/Indexing/SessionSnapshotWriter.swift")
        let mergeStart = try XCTUnwrap(source.range(of: "private func mergeSessionSnapshot"))
        let mergeEnd = try XCTUnwrap(source.range(of: "private func clearRecoveredOrphanStatus", options: [], range: mergeStart.lowerBound..<source.endIndex))
        let merge = String(source[mergeStart.lowerBound..<mergeEnd.lowerBound])

        XCTAssertTrue(
            merge.contains("incoming.sourceLocator == current.sourceLocator"),
            "same hash/size snapshots must not no-op when the file moved to a new local source locator"
        )

        let upsertStart = try XCTUnwrap(source.range(of: "file_path = CASE"))
        let upsertEnd = try XCTUnwrap(source.range(of: "sync_version = excluded.sync_version", options: [], range: upsertStart.lowerBound..<source.endIndex))
        let filePathCase = String(source[upsertStart.lowerBound..<upsertEnd.lowerBound])

        XCTAssertTrue(filePathCase.contains("excluded.source_locator NOT LIKE 'sync://%'"))
        XCTAssertTrue(
            filePathCase.contains("sessions.source_locator != excluded.source_locator"),
            "a moved local source locator must refresh the persisted file_path used by FTS reads"
        )
        XCTAssertTrue(filePathCase.contains("THEN excluded.source_locator"))
    }

    func testFtsRebuildPolicyOnlyReopensCompletedJobsWhenRebuildStarts() throws {
        let source = try source("EngramCoreWrite/Database/FTSRebuildPolicy.swift")
        XCTAssertTrue(source.contains("let startedRebuild = pending != expectedVersion || rebuildTableMissing"))

        let reopenStart = try XCTUnwrap(source.range(of: "UPDATE session_index_jobs"))
        let prefixStart = source.index(reopenStart.lowerBound, offsetBy: -160, limitedBy: source.startIndex) ?? source.startIndex
        let reopenBlock = String(source[prefixStart..<reopenStart.lowerBound])

        XCTAssertTrue(
            reopenBlock.contains("if startedRebuild"),
            "completed FTS jobs must be reopened only on the first apply of a rebuild"
        )
    }

    func testFtsRebuildRetryPathCanBecomeTerminalAndFinalize() throws {
        let source = try source("EngramCoreWrite/Indexing/IndexJobRunner.swift")

        XCTAssertTrue(source.contains("private static let maxFtsRetryCount"))

        let catchStart = try XCTUnwrap(source.range(of: "} catch {"))
        let catchEnd = try XCTUnwrap(source.range(of: "return .retryable", options: [], range: catchStart.lowerBound..<source.endIndex))
        let retryCatch = String(source[catchStart.lowerBound..<catchEnd.upperBound])
        XCTAssertTrue(retryCatch.contains("try Self.markRetryable"))
        XCTAssertTrue(
            retryCatch.contains("try FTSRebuildPolicy.finalizeRebuildIfReady(db)"),
            "a retryable failure that hits the retry cap must not leave a rebuild permanently pending"
        )

        let markStart = try XCTUnwrap(source.range(of: "static func markRetryable"))
        let markEnd = try XCTUnwrap(source.range(of: "}", options: [], range: markStart.lowerBound..<source.endIndex))
        let markRetryable = String(source[markStart.lowerBound...markEnd.lowerBound])
        XCTAssertTrue(markRetryable.contains("retry_count + 1 >= ?"))
        XCTAssertTrue(markRetryable.contains("failed_permanent"))
    }

    func testRegenerateAllTitlesStartsBackgroundWorkBeforeReturning() throws {
        let source = try source("EngramService/Core/EngramServiceCommandHandler.swift")

        XCTAssertTrue(source.contains("private static let titleRegenerationCoordinator"))
        XCTAssertTrue(source.contains("ServiceTitleRegenerationCoordinator"))

        let handlerStart = try XCTUnwrap(source.range(of: "case \"regenerateAllTitles\":"))
        let handlerEnd = try XCTUnwrap(source.range(of: "case \"projectMove\":", options: [], range: handlerStart.lowerBound..<source.endIndex))
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        XCTAssertFalse(
            handler.contains("databaseGeneration:"),
            "bulk title regeneration should return started immediately instead of waiting for the write command generation"
        )

        let start = try XCTUnwrap(source.range(of: "private static func regenerateAllTitles"))
        let end = try XCTUnwrap(source.range(of: "private static func regenerateAllTitlesInBackground", options: [], range: start.lowerBound..<source.endIndex))
        let regenerate = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(regenerate.contains("titleRegenerationCoordinator.start"))
        XCTAssertTrue(regenerate.contains("status: \"started\""))
        XCTAssertFalse(regenerate.contains("let generatedTitles = try await generateTitlesForContexts"))
        XCTAssertFalse(regenerate.contains("return try await writerGate.performWriteCommand"))
    }

    func testPolycliProviderParentsWriteScoreMatchesAsSuggestions() throws {
        let source = try source("EngramCoreWrite/Indexing/StartupBackfills.swift")
        let start = try XCTUnwrap(source.range(of: "public static func backfillPolycliProviderParents"))
        let end = try XCTUnwrap(source.range(of: "private static func scoredPolycliHosts", options: [], range: start.lowerBound..<source.endIndex))
        let backfill = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(backfill.contains("var suggested = 0"))
        XCTAssertTrue(backfill.contains("try setSuggestedParent(db, sessionId: id, suggestedParentId: best.parentId)"))
        XCTAssertTrue(backfill.contains("suggested += 1"))
        XCTAssertTrue(backfill.contains("ProviderParentResult(checked: checked, classified: classified, linked: linked, suggested: suggested)"))
        XCTAssertFalse(backfill.contains("setParentSession"))
        XCTAssertFalse(backfill.contains(#"linkSource: "path""#))
    }

    func testPolycliProviderParentEventsExposeSuggestedCount() throws {
        let source = try source("EngramCoreWrite/Indexing/StartupBackfills.swift")
        let start = try XCTUnwrap(source.range(of: "let providerParents = try database.backfillPolycliProviderParents()"))
        let end = try XCTUnwrap(source.range(of: "let suggestions = try database.backfillSuggestedParents()", options: [], range: start.lowerBound..<source.endIndex))
        let eventBlock = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(eventBlock.contains("providerParents.suggested > 0"))
        XCTAssertTrue(eventBlock.contains(#""linked": .int(providerParents.linked)"#))
        XCTAssertTrue(eventBlock.contains(#""suggested": .int(providerParents.suggested)"#))
    }

    func testWriterGateSuspendsQueueTimeoutBehindProjectMigrationCommands() throws {
        let source = try source("EngramService/Core/ServiceWriterGate.swift")
        let start = try XCTUnwrap(source.range(of: "public func performWriteCommand"))
        let end = try XCTUnwrap(source.range(of: "public func checkpointWal()", options: [], range: start.lowerBound..<source.endIndex))
        let performWrite = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains("private var longRunningWriteInProgress = false"))
        XCTAssertTrue(source.contains("private static func isLongRunningWriteCommand"))
        XCTAssertTrue(source.contains(#""projectMove""#))
        XCTAssertTrue(source.contains(#""projectArchive""#))
        XCTAssertTrue(source.contains(#""projectUndo""#))
        XCTAssertTrue(source.contains(#""projectMoveBatch""#))
        XCTAssertTrue(performWrite.contains("let timeout = longRunningWriteInProgress ? nil : queueTimeoutNanoseconds"))
        XCTAssertTrue(performWrite.contains("longRunningWriteInProgress = Self.isLongRunningWriteCommand(name)"))
        XCTAssertTrue(performWrite.contains("longRunningWriteInProgress = false"))
    }

    func testProjectMoveCanonicalizesExistingSourceToOnDiskCaseOnly() throws {
        let source = try source("EngramCoreWrite/ProjectMove/Orchestrator.swift")
        let runStart = try XCTUnwrap(source.range(of: "public static func run("))
        let dryRunStart = try XCTUnwrap(source.range(of: "// Dry-run:", options: [], range: runStart.lowerBound..<source.endIndex))
        let validation = String(source[runStart.lowerBound..<dryRunStart.lowerBound])

        XCTAssertTrue(validation.contains("let src = canonicalizeExistingSource(options.src)"))
        XCTAssertFalse(validation.contains("let src = canonicalize(options.src)"))

        let helperStart = try XCTUnwrap(source.range(of: "private func canonicalizeExistingSource"))
        let helperEnd = try XCTUnwrap(source.range(of: "private func basename", options: [], range: helperStart.lowerBound..<source.endIndex))
        let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        XCTAssertTrue(helper.contains("realpathSafe"))
        XCTAssertTrue(helper.contains("caseInsensitiveCompare"))
        XCTAssertTrue(helper.contains("return realPath"))
        XCTAssertTrue(helper.contains("return path"))
    }

    func testBatchArchiveDryRunDoesNotCreateDestinationParents() throws {
        let source = try source("EngramCoreWrite/ProjectMove/Batch.swift")
        let archiveStart = try XCTUnwrap(source.range(of: "} else if op.archive {"))
        let archiveEnd = try XCTUnwrap(source.range(of: "} else {", options: [], range: archiveStart.lowerBound..<source.endIndex))
        let archiveBranch = String(source[archiveStart.lowerBound..<archiveEnd.lowerBound])

        XCTAssertTrue(archiveBranch.contains("skipProbe: doc.defaults.dryRun"))
        XCTAssertTrue(archiveBranch.contains("if !doc.defaults.dryRun"))
        XCTAssertTrue(archiveBranch.contains("FileManager.default.createDirectory"))
    }

    func testBatchResultEncodesOperationProjectPaths() throws {
        let orchestrator = try source("EngramCoreWrite/ProjectMove/Orchestrator.swift")
        let pipelineStart = try XCTUnwrap(orchestrator.range(of: "public struct PipelineResult"))
        let optionsStart = try XCTUnwrap(orchestrator.range(of: "public struct RunProjectMoveOptions", options: [], range: pipelineStart.lowerBound..<orchestrator.endIndex))
        let pipeline = String(orchestrator[pipelineStart.lowerBound..<optionsStart.lowerBound])

        XCTAssertTrue(pipeline.contains("public let src: String"))
        XCTAssertTrue(pipeline.contains("public let dst: String"))

        let service = try source("EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift")
        let encodeStart = try XCTUnwrap(service.range(of: "private static func encodeBatchResult"))
        let encodeEnd = try XCTUnwrap(service.range(of: "let failed:", options: [], range: encodeStart.lowerBound..<service.endIndex))
        let encode = String(service[encodeStart.lowerBound..<encodeEnd.lowerBound])

        XCTAssertTrue(encode.contains(#""src": .string(pr.src)"#))
        XCTAssertTrue(encode.contains(#""dst": .string(pr.dst)"#))
        XCTAssertFalse(encode.contains("renamedDirs.first"))
    }

    func testProjectMoveDryRunCountsWithPatchSemantics() throws {
        let source = try source("EngramCoreWrite/ProjectMove/Orchestrator.swift")
        let dryRunStart = try XCTUnwrap(source.range(of: "static func buildDryRunPlan"))
        let dryRunEnd = try XCTUnwrap(source.range(of: "// MARK: - helpers", options: [], range: dryRunStart.lowerBound..<source.endIndex))
        let dryRun = String(source[dryRunStart.lowerBound..<dryRunEnd.lowerBound])

        XCTAssertTrue(dryRun.contains("try JsonlPatch.patchBufferWithDotQuote"))
        XCTAssertTrue(dryRun.contains("oldPath: src"))
        XCTAssertTrue(dryRun.contains("newPath: dst"))
        XCTAssertTrue(dryRun.contains("let fileOccurrences = patchResult.count"))
        XCTAssertFalse(dryRun.contains("countOccurrences(of:"))
        XCTAssertFalse(dryRun.contains("Data(src.utf8)"))
    }

    func testProjectMovePathVariantHelperIsSharedAcrossPatchAndDatabaseRewrite() throws {
        let sources = try source("EngramCoreWrite/ProjectMove/Sources.swift")
        XCTAssertTrue(sources.contains("enum ProjectPathVariants"))
        XCTAssertTrue(sources.contains("path.precomposedStringWithCanonicalMapping"))
        XCTAssertTrue(sources.contains("path.decomposedStringWithCanonicalMapping"))

        let patch = try source("EngramCoreWrite/ProjectMove/JsonlPatch.swift")
        XCTAssertTrue(patch.contains("for variant in ProjectPathVariants.variants(oldPath) where variant != newPath"))
        XCTAssertTrue(patch.contains("replaceWithTerminator("))
        XCTAssertTrue(patch.contains("let needle = Data((variant +"))

        let store = try source("EngramCoreWrite/ProjectMove/MigrationLogStore.swift")
        XCTAssertTrue(store.contains("let oldVariants = ProjectPathVariants.variants(oldPath)"))
        XCTAssertTrue(store.contains(#""old0": oldVariants[0]"#))
        XCTAssertTrue(store.contains(#""old1": oldVariants[1]"#))
        XCTAssertTrue(store.contains(#""old2": oldVariants[2]"#))
        XCTAssertTrue(store.contains("let old = \":old\\(idx)\""))
        XCTAssertTrue(store.contains("SUBSTR(\\(col), 1, LENGTH(\\(old)) + 1)"))
        XCTAssertFalse(store.contains(#"StatementArguments = ["old": oldPath, "new": newPath]"#))
    }

    func testProjectMoveServiceResponseCapsUnboundedPayloadFields() throws {
        let source = try source("EngramService/Core/EngramServiceCommandHandler+ProjectMigration.swift")
        let start = try XCTUnwrap(source.range(of: "private static func mapPipelineResult"))
        let end = try XCTUnwrap(source.range(of: "private static func encodeBatchResult", options: [], range: start.lowerBound..<source.endIndex))
        let mapper = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(source.contains("private static let projectMovePayloadListLimit"))
        XCTAssertTrue(source.contains("private static let projectMovePayloadStringLimit"))
        XCTAssertTrue(source.contains("private static func cappedProjectMoveString"))
        XCTAssertTrue(mapper.contains(".prefix(Self.projectMovePayloadListLimit)"))
        XCTAssertTrue(mapper.contains("Self.cappedProjectMoveString"))
        XCTAssertFalse(mapper.contains("own: result.review.own,\n            other: result.review.other"))
        XCTAssertFalse(mapper.contains("porcelain: result.git.porcelain"))
    }

    func testRecentIndexSkipsUnchangedFileLocatorsBeforeParsing() async throws {
        let temp = try makeTempDir("index-skip")
        defer { try? FileManager.default.removeItem(at: temp) }
        let locator = temp.appendingPathComponent("session.jsonl")
        try #"{"role":"user","content":"hello"}"#.write(to: locator, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: locator.path)[.size] as? NSNumber
        ).int64Value
        let sink = Round5KnownFileStateSink(states: [
            locator.path: KnownIndexedFileState(sizeBytes: size, indexedAt: "2999-01-01T00:00:00Z")
        ])
        let adapter = Round5CountingFileSessionAdapter(locator: locator.path, sizeBytes: size)
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [adapter],
            skipUnchangedFileLocators: true
        )

        let indexed = try await indexer.indexAll()

        XCTAssertEqual(indexed, 0)
        XCTAssertEqual(adapter.parseCount, 0)
        XCTAssertTrue(sink.batchSizes.isEmpty)
    }

    func testRecentIndexParsesSameSizeFileModifiedAfterIndexedAt() async throws {
        let temp = try makeTempDir("index-same-size")
        defer { try? FileManager.default.removeItem(at: temp) }
        let locator = temp.appendingPathComponent("session.jsonl")
        try "abc".write(to: locator, atomically: true, encoding: .utf8)
        let modifiedAt = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: locator.path)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: locator.path)[.size] as? NSNumber
        ).int64Value
        let sink = Round5KnownFileStateSink(states: [
            locator.path: KnownIndexedFileState(sizeBytes: size, indexedAt: "1970-01-01T00:00:01Z")
        ])
        let adapter = Round5CountingFileSessionAdapter(locator: locator.path, sizeBytes: size)
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [adapter],
            skipUnchangedFileLocators: true
        )

        let indexed = try await indexer.indexAll()

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(adapter.parseCount, 1)
        XCTAssertEqual(sink.batchSizes, [1])
    }

    // Part B — Cline cwd extraction must anchor on ") Files" so a path that
    // itself contains ')' is not truncated at the first ')'.
    func testClineCwdAnchorsOnFilesSuffixForPathContainingParen() async throws {
        let tasksRoot = try makeTempDir("cline")
        defer { try? FileManager.default.removeItem(at: tasksRoot) }
        let taskDir = tasksRoot.appendingPathComponent("task-1", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)

        let parenPath = "/Users/test/proj (work)/repo"
        let requestText = "Current Working Directory (\(parenPath)) Files\nfoo.swift"
        let innerRequest = try JSONSerialization.data(withJSONObject: ["request": requestText])
        let requestString = String(data: innerRequest, encoding: .utf8)!

        let messages: [[String: Any]] = [
            ["ts": 1_000, "say": "task", "text": "do the thing"],
            ["ts": 1_001, "say": "api_req_started", "text": requestString],
            ["ts": 1_002, "say": "text", "text": "done"]
        ]
        try writeJSON(messages, to: taskDir.appendingPathComponent("ui_messages.json"))

        let adapter = ClineAdapter(tasksRoot: tasksRoot.path)
        let locators = try await adapter.listSessionLocators()
        guard let locator = locators.first,
              case let .success(info) = try await adapter.parseSessionInfo(locator: locator)
        else {
            XCTFail("Cline fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, parenPath)
    }

    // Falls back to the loose pattern for caches that lack the " Files" trailer.
    func testClineCwdFallsBackWhenNoFilesSuffix() async throws {
        let tasksRoot = try makeTempDir("cline-fallback")
        defer { try? FileManager.default.removeItem(at: tasksRoot) }
        let taskDir = tasksRoot.appendingPathComponent("task-2", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)

        let requestText = "Current Working Directory (/Users/test/plain)"
        let innerRequest = try JSONSerialization.data(withJSONObject: ["request": requestText])
        let requestString = String(data: innerRequest, encoding: .utf8)!
        let messages: [[String: Any]] = [
            ["ts": 1_000, "say": "task", "text": "do the thing"],
            ["ts": 1_001, "say": "api_req_started", "text": requestString]
        ]
        try writeJSON(messages, to: taskDir.appendingPathComponent("ui_messages.json"))

        let adapter = ClineAdapter(tasksRoot: tasksRoot.path)
        let locator = try await adapter.listSessionLocators().first!
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: locator) else {
            XCTFail("Cline fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, "/Users/test/plain")
    }

    func testClineDiscoveryDoesNotTraverseSymlinkedTaskDirectories() async throws {
        let tasksRoot = try makeTempDir("cline-symlink-root")
        let outside = try makeTempDir("cline-symlink-outside")
        defer {
            try? FileManager.default.removeItem(at: tasksRoot)
            try? FileManager.default.removeItem(at: outside)
        }
        let messages: [[String: Any]] = [
            ["ts": 1_000, "say": "task", "text": "outside task"]
        ]
        try writeJSON(messages, to: outside.appendingPathComponent("ui_messages.json"))
        do {
            try FileManager.default.createSymbolicLink(
                at: tasksRoot.appendingPathComponent("linked-task"),
                withDestinationURL: outside
            )
        } catch {
            throw XCTSkip("symlink permission denied: \(error.localizedDescription)")
        }

        let adapter = ClineAdapter(tasksRoot: tasksRoot.path)
        let locators = try await adapter.listSessionLocators()

        XCTAssertTrue(locators.isEmpty, "discovery must not traverse symlinked task directories: \(locators)")
    }

    // Part B — Windsurf must surface cwd from the Cascade conversation summary
    // when the cache metadata carries it.
    func testWindsurfSurfacesCwdFromCacheMetadata() async throws {
        let cacheDir = try makeTempDir("windsurf")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let lines = [
            #"{"id":"conv-1","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z","cwd":"/Users/test/ws-project"}"#,
            #"{"role":"user","content":"hi","timestamp":"2026-02-18T09:00:00.000Z"}"#
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: cacheDir.appendingPathComponent("conv-1.jsonl"), atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(cacheDir: cacheDir.path, enableLiveSync: false)
        let locator = try await adapter.listSessionLocators().first!
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: locator) else {
            XCTFail("Windsurf fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, "/Users/test/ws-project")
    }

    // Empty cwd remains empty when metadata lacks the field (backward compatible).
    func testWindsurfCwdEmptyWhenMetadataMissing() async throws {
        let cacheDir = try makeTempDir("windsurf-empty")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let lines = [
            #"{"id":"conv-2","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z"}"#,
            #"{"role":"user","content":"hi","timestamp":"2026-02-18T09:00:00.000Z"}"#
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: cacheDir.appendingPathComponent("conv-2.jsonl"), atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(cacheDir: cacheDir.path, enableLiveSync: false)
        let locator = try await adapter.listSessionLocators().first!
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: locator) else {
            XCTFail("Windsurf fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, "")
    }

    // Part B — Codex counts a tool invocation once (function_call only), not both
    // the function_call and its paired function_call_output.
    func testCodexCountsToolUseOncePerFunctionCall() async throws {
        let root = try makeTempDir("codex")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-sample.jsonl")
        try writeJSONL(
            [
                ["type": "session_meta", "timestamp": "2026-01-15T10:00:00Z", "payload": ["id": "s1", "timestamp": "2026-01-15T10:00:00Z", "cwd": "/repo"]],
                ["type": "response_item", "timestamp": "2026-01-15T10:00:01Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "fix it"]]]],
                ["type": "response_item", "timestamp": "2026-01-15T10:00:02Z", "payload": ["type": "function_call", "name": "read_file", "arguments": ["path": "a.ts"]]],
                ["type": "response_item", "timestamp": "2026-01-15T10:00:03Z", "payload": ["type": "function_call_output", "output": "contents"]]
            ],
            to: file
        )

        let adapter = CodexAdapter(sessionsRoot: root.path)
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: file.path) else {
            XCTFail("Codex fixture should parse")
            return
        }
        // 1 user + 0 assistant + 1 tool (function_call only).
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.messageCount, 2)
    }

    func testCodexDiscoveryDoesNotTraverseSymlinkedDirectories() async throws {
        let root = try makeTempDir("codex-symlink-root")
        let outside = try makeTempDir("codex-symlink-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try writeJSONL(
            [
                ["type": "session_meta", "timestamp": "2026-01-15T10:00:00Z", "payload": ["id": "outside", "cwd": "/secret"]]
            ],
            to: outside.appendingPathComponent("rollout-outside.jsonl")
        )
        do {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: outside
            )
        } catch {
            throw XCTSkip("symlink permission denied: \(error.localizedDescription)")
        }

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let locators = try await adapter.listSessionLocators()

        XCTAssertTrue(locators.isEmpty, "discovery must not traverse symlinked source directories: \(locators)")
    }

    // Part A R5-50 — StreamingLineReader.failures reads are race-free; an
    // oversized line is reported as a failure without crashing.
    func testStreamingLineReaderReportsOversizedLineSafely() throws {
        let dir = try makeTempDir("reader")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.jsonl")
        let big = String(repeating: "x", count: 64) + "\nok\n"
        try big.write(to: file, atomically: true, encoding: .utf8)

        let reader = try StreamingLineReader(fileURL: file, maxLineBytes: 8)
        var lines: [String] = []
        for line in try reader.readLines() {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["ok"])
        XCTAssertEqual(reader.failures, [.lineTooLarge])
    }

    func testJSONLReadObjectsDegradesPastMessageLimit() throws {
        let dir = try makeTempDir("jsonl-limit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let lines = (0..<3).map { #"{"type":"response_item","payload":{"index":\#($0)}}"# }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: file.path,
            limits: ParserLimits(maxMessages: 2)
        )

        XCTAssertNil(failure)
        XCTAssertEqual(objects.count, 2)
    }

    func testJSONLReadObjectsSkipsOversizedLineWithoutFailingFile() throws {
        let dir = try makeTempDir("jsonl-big-line")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let valid = #"{"ok":true}"#
        try (String(repeating: "x", count: 128) + "\n" + valid)
            .write(to: file, atomically: true, encoding: .utf8)

        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: file.path,
            limits: ParserLimits(maxLineBytes: 64)
        )

        XCTAssertNil(failure)
        XCTAssertEqual(objects.count, 1)
    }

    func testJSONLReadObjectsSkipsInvalidUTF8LineWithoutFailingFile() throws {
        let dir = try makeTempDir("jsonl-invalid-utf8")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        var data = Data([0xff, 0x0a])
        data.append(#"{"type":"response_item","payload":{"ok":true}}"#.data(using: .utf8)!)
        try data.write(to: file)

        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: file.path, limits: .default)

        XCTAssertNil(failure)
        XCTAssertEqual(objects.count, 1)
    }

    func testJSONLRepeatedReadsDoNotRetainAutoreleasedParserObjects() throws {
        let dir = try makeTempDir("jsonl-autorelease")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let payload = String(repeating: "x", count: 2_048)
        let lines = (0..<1_000).map { index in
            #"{"type":"user","sessionId":"s","timestamp":"2026-05-24T00:00:00Z","message":{"content":[{"type":"text","text":"\#(payload)-\#(index)"}]}}"#
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let limits = ParserLimits(maxFileBytes: 16 * 1024 * 1024)
        let baseline = currentResidentMemoryBytes()
        for _ in 0..<60 {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: file.path, limits: limits)
            XCTAssertNil(failure)
            XCTAssertEqual(objects.count, 1_000)
        }
        let growth = currentResidentMemoryBytes() - baseline
        XCTAssertLessThan(
            growth,
            128 * 1024 * 1024,
            "Repeated JSONL reads should drain autoreleased JSONSerialization objects between files"
        )
    }
}

private final class Round5KnownFileStateSink: IndexingWriteSink {
    let states: [String: KnownIndexedFileState]
    var batchSizes: [Int] = []

    init(states: [String: KnownIndexedFileState]) {
        self.states = states
    }

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        batchSizes.append(snapshots.count)
        return SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .merge, enqueuedJobs: [])
            }
        )
    }

    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState] {
        states.filter { locators.contains($0.key) }
    }
}

private final class Round5CountingFileSessionAdapter: SessionAdapter {
    let source: SourceName = .claudeCode
    let locator: String
    let sizeBytes: Int64
    var parseCount = 0

    init(locator: String, sizeBytes: Int64) {
        self.locator = locator
        self.sizeBytes = sizeBytes
    }

    func detect() async -> Bool {
        true
    }

    func listSessionLocators() async throws -> [String] {
        [locator]
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        parseCount += 1
        return .success(
            NormalizedSessionInfo(
                id: "counting",
                source: source,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "synthetic",
                messageCount: 1,
                userMessageCount: 1,
                assistantMessageCount: 0,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "hello",
                filePath: locator,
                sizeBytes: sizeBytes
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(NormalizedMessage(role: .user, content: "hello"))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool {
        true
    }
}

private func currentResidentMemoryBytes() -> UInt64 {
    var info = proc_taskinfo()
    let result = proc_pidinfo(
        getpid(),
        PROC_PIDTASKINFO,
        0,
        &info,
        Int32(MemoryLayout<proc_taskinfo>.size)
    )
    guard result == Int32(MemoryLayout<proc_taskinfo>.size) else { return 0 }
    return UInt64(info.pti_resident_size)
}

import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

final class CollectorPOSIXRootEnumeratorTests: XCTestCase {
    func testConstructorRejectsUnsupportedUnsafeAndUnboundedBindingsWithoutSourceIO() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let identity = try fixture.identity()
        let invalid = [
            fixture.configuration(source: .cursor),
            fixture.configuration(rootID: ""),
            fixture.configuration(revision: 0),
            fixture.configuration(path: "relative/root"),
            fixture.configuration(path: "/"),
            fixture.configuration(path: fixture.sourceRoot.path + "/../sessions"),
            fixture.configuration(path: fixture.sourceRoot.path + "//nested"),
            fixture.configuration(path: fixture.sourceRoot.path + "/nul\0name"),
            fixture.configuration(path: "/" + Array(repeating: "a", count: 33).joined(separator: "/")),
            fixture.configuration(path: "/" + String(repeating: "x", count: Int(MAXPATHLEN))),
        ]
        for configuration in invalid {
            XCTAssertThrowsError(try CollectorPOSIXRootEnumerator(
                binding: .init(configuration: configuration, expectedIdentity: identity), testHooks: fixture.hooks
            )) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .invalidBinding) }
        }
        let missing = fixture.configuration(path: fixture.base.appendingPathComponent("not-created").path)
        _ = try CollectorPOSIXRootEnumerator(binding: .init(configuration: missing, expectedIdentity: identity), testHooks: fixture.hooks)
        XCTAssertEqual(fixture.descriptors.openedCount, 0, "construction must not enroll or inspect a root")
        XCTAssertEqual(CollectorPOSIXRootEnumerator.maximumAbsoluteComponents, 32)
        XCTAssertEqual(CollectorPOSIXRootEnumerator.maximumRelativeDepth, 32)
        XCTAssertEqual(CollectorPOSIXRootEnumerator.maximumPathBytes, Int(MAXPATHLEN) - 1)
    }

    func testOpenRequiresByteExactRootIDPathSourceAndRevisionBeforeSourceIO() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let configuration = fixture.configuration(rootID: "root-e\u{301}")
        let enumerator = try fixture.enumerator(configuration: configuration)
        let mismatches = [
            fixture.configuration(rootID: "root-é"),
            fixture.configuration(rootID: configuration.rootID, source: .claudeCode),
            fixture.configuration(rootID: configuration.rootID, revision: 2),
            fixture.configuration(rootID: configuration.rootID, path: fixture.sourceRoot.path.uppercased()),
        ]
        for other in mismatches {
            XCTAssertThrowsError(try enumerator.open(configuration: other, relativeDirectory: "")) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .configurationMismatch)
            }
        }
        let composedPath = fixture.sourceRoot.path + "/é"
        let pathConfiguration = fixture.configuration(path: composedPath)
        let pathEnumerator = try fixture.enumerator(configuration: pathConfiguration)
        XCTAssertThrowsError(try pathEnumerator.open(
            configuration: fixture.configuration(path: fixture.sourceRoot.path + "/e\u{301}"), relativeDirectory: ""
        )) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .configurationMismatch) }
        XCTAssertEqual(fixture.descriptors.openedCount, 0)
    }

    func testEveryExpectedRootIdentityFieldIsRequiredWithoutAutomaticFallback() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let expected = try fixture.identity()
        let mismatches = [
            CollectorPOSIXDirectoryIdentity(device: expected.device + 1, inode: expected.inode, generation: expected.generation, birthSeconds: expected.birthSeconds, birthNanoseconds: expected.birthNanoseconds),
            CollectorPOSIXDirectoryIdentity(device: expected.device, inode: expected.inode + 1, generation: expected.generation, birthSeconds: expected.birthSeconds, birthNanoseconds: expected.birthNanoseconds),
            CollectorPOSIXDirectoryIdentity(device: expected.device, inode: expected.inode, generation: expected.generation ^ 1, birthSeconds: expected.birthSeconds, birthNanoseconds: expected.birthNanoseconds),
            CollectorPOSIXDirectoryIdentity(device: expected.device, inode: expected.inode, generation: expected.generation, birthSeconds: expected.birthSeconds + 1, birthNanoseconds: expected.birthNanoseconds),
            CollectorPOSIXDirectoryIdentity(device: expected.device, inode: expected.inode, generation: expected.generation, birthSeconds: expected.birthSeconds, birthNanoseconds: (expected.birthNanoseconds + 1) % 1_000_000_000),
        ]
        for mismatch in mismatches {
            let enumerator = try fixture.enumerator(identity: mismatch)
            XCTAssertThrowsError(try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged)
            }
            XCTAssertTrue(fixture.descriptors.live.isEmpty)
        }
        XCTAssertEqual(try fixture.identity(), expected)
    }

    func testRootAndAncestorSymlinksAreRejectedInsteadOfCanonicalized() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let leafAlias = fixture.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: leafAlias, withDestinationURL: fixture.sourceRoot)
        let ancestorAlias = fixture.base.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: ancestorAlias, withDestinationURL: fixture.base)
        for path in [leafAlias.path, ancestorAlias.appendingPathComponent(fixture.sourceRoot.lastPathComponent).path] {
            let configuration = fixture.configuration(path: path)
            let enumerator = try fixture.enumerator(configuration: configuration)
            XCTAssertThrowsError(try enumerator.open(configuration: configuration, relativeDirectory: "")) {
                self.assertUnsafePathError($0)
            }
            XCTAssertTrue(fixture.descriptors.live.isEmpty)
        }
    }

    func testRelativeTraversalAndDepthLimitsAreRejectedBeforeSourceIO() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let enumerator = try fixture.enumerator()
        for path in ["/absolute", ".", "..", "a/../b", "a/./b", "a//b", "a/", "nul\0name"] {
            XCTAssertThrowsError(try enumerator.open(configuration: fixture.configuration(), relativeDirectory: path)) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .unsafePath)
            }
        }
        XCTAssertThrowsError(try enumerator.open(
            configuration: fixture.configuration(), relativeDirectory: Array(repeating: "a", count: 33).joined(separator: "/")
        )) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .depthLimit) }
        XCTAssertThrowsError(try enumerator.open(
            configuration: fixture.configuration(), relativeDirectory: String(repeating: "x", count: Int(MAXPATHLEN))
        )) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .unsafePath) }
        XCTAssertEqual(fixture.descriptors.openedCount, 0)
    }

    func testRootReplacementBeforeOpenDoesNotBindTheNewInode() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let enumerator = try fixture.enumerator()
        try fixture.replaceRoot()
        XCTAssertThrowsError(try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")) {
            XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged)
        }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testRelativeDepthThirtyTwoIsAcceptedAtTheDeclaredBoundary() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let directory = Array(repeating: "d", count: 32).joined(separator: "/")
        let path = directory + "/rollout-one.jsonl"
        try fixture.file(path)
        let entries = try fixture.readDirectory(relativeDirectory: directory)
        XCTAssertEqual(entries.compactMap { entry -> String? in
            if case .file(let file) = entry { return file.relativePath }; return nil
        }, [path])
        XCTAssertLessThanOrEqual(fixture.descriptors.maximumLive, 3)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testRootReplacementAfterOpenRejectsOldDirectoryAliasAndClosesStream() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-old.jsonl")
        let enumerator = try fixture.enumerator()
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        try fixture.replaceRoot()
        try fixture.file("rollout-replacement.jsonl")
        XCTAssertThrowsError(try cursor!.next()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged) }
        XCTAssertTrue(fixture.descriptors.live.isEmpty, "the failed cursor is still alive")
    }

    func testRootReplacementAfterEntryReadCannotEmitTheOldEntry() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-old.jsonl")
        var replaced = false
        var hooks = fixture.hooks
        hooks.afterReadEntry = { name in
            guard name == "rollout-old.jsonl", !replaced else { return }
            replaced = true
            try fixture.replaceRoot()
        }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        XCTAssertThrowsError(try cursor!.next()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged) }
        XCTAssertTrue(replaced)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testRootReplacementAtEOFIsNotSuccessfulEOF() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        var replaced = false
        var hooks = fixture.hooks
        hooks.afterReadEntry = { name in
            guard name == nil, !replaced else { return }
            replaced = true
            try fixture.replaceRoot()
        }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        XCTAssertThrowsError(try cursor!.next()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .rootIdentityChanged) }
        XCTAssertTrue(replaced)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testCurrentDirectoryReplacementBeforeNextIsRejected() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("nested/rollout-old.jsonl")
        let enumerator = try fixture.enumerator()
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "nested")
        defer { cursor = nil }
        try fixture.replaceDirectory("nested")
        XCTAssertThrowsError(try cursor!.next()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .directoryIdentityChanged) }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testCurrentDirectoryReplacementAfterReadIsRejected() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("nested/rollout-old.jsonl")
        var replaced = false
        var hooks = fixture.hooks
        hooks.afterReadEntry = { name in
            guard name == "rollout-old.jsonl", !replaced else { return }
            replaced = true
            try fixture.replaceDirectory("nested")
        }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "nested")
        defer { cursor = nil }
        XCTAssertThrowsError(try cursor!.next()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .directoryIdentityChanged) }
        XCTAssertTrue(replaced)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testDirectoryMembershipChangeAtEOFRequiresReconciliation() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        var changed = false
        var hooks = fixture.hooks
        hooks.afterReadEntry = { name in
            guard name == nil, !changed else { return }
            changed = true
            try fixture.file("rollout-new.jsonl")
            try fixture.advanceDirectoryTimestamp()
        }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        XCTAssertThrowsError(try cursor!.next()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .directoryContentsChanged) }
        XCTAssertTrue(changed)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testClaudeLayoutIncludesHiddenProjectsButNotHiddenProjectEntriesOrWorkflowJournals() throws {
        let fixture = try CollectorPOSIXFixture(source: .claudeCode)
        defer { fixture.remove() }
        let expected = [
            "project/session.jsonl", ".hidden-project/session.jsonl",
            "project/session/subagents/agent-child.jsonl",
            "project/session/subagents/workflows/wf_one/agent-worker.jsonl",
        ]
        let excluded = [
            "root.jsonl", "project/.hidden.jsonl", "project/.hidden-session/subagents/agent-no.jsonl",
            "project/memory/notes.jsonl", "project/session/subagents/.hidden.jsonl",
            "project/session/subagents/workflows/wf_one/journal.jsonl",
            "project/session/subagents/workflows/not-a-run/agent-no.jsonl",
            "project/session/workflows/wf_one/agent-no.jsonl",
        ]
        for path in expected + excluded { try fixture.file(path) }
        let result = try fixture.enumerateSelectedFiles()
        XCTAssertEqual(Set(result), Set(expected))
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testCodexOnlyEnumeratesExplicitRootWithoutArchiveSiblingOrHiddenDescent() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        for path in ["rollout-root.jsonl", "2026/09/06/rollout-day.jsonl", "custom/rollout-other.jsonl"] {
            try fixture.file(path)
        }
        for path in [".hidden/rollout-no.jsonl", "nested/.rollout-no.jsonl", "nested/notes.jsonl", "nested/rollout-upper.JSONL"] {
            try fixture.file(path)
        }
        let archive = fixture.base.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        try Data("unlisted sibling".utf8).write(to: archive.appendingPathComponent("rollout-archive.jsonl"))
        XCTAssertEqual(Set(try fixture.enumerateSelectedFiles()), ["rollout-root.jsonl", "2026/09/06/rollout-day.jsonl", "custom/rollout-other.jsonl"])
        XCTAssertFalse(fixture.descriptors.openedPaths.contains { $0.contains("archived_sessions") })
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testLeafTypesAreCheckedWithoutFollowingLinksOrOpeningCandidateContents() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-unreadable.jsonl", bytes: Data([0xFF, 0x00, 0xFE]))
        XCTAssertEqual(chmod(fixture.url("rollout-unreadable.jsonl").path, 0), 0)
        let outside = fixture.base.appendingPathComponent("outside.jsonl")
        try Data("must not read".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.url("rollout-link.jsonl"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.url("linked-directory"), withDestinationURL: fixture.base)
        XCTAssertEqual(mkfifo(fixture.url("rollout-fifo.jsonl").path, 0o600), 0)
        let entries = try fixture.readDirectory()
        XCTAssertEqual(entries.compactMap { entry -> String? in if case .file(let file) = entry { return file.relativePath }; return nil }, ["rollout-unreadable.jsonl"])
        XCTAssertTrue(entries.contains(.symlink("rollout-link.jsonl")))
        XCTAssertTrue(entries.contains(.symlink("linked-directory")))
        XCTAssertTrue(entries.contains(.ignored("rollout-fifo.jsonl")))
        XCTAssertTrue(fixture.descriptors.openedKinds.allSatisfy { $0 == S_IFDIR }, "candidate bodies must never receive an fd")
        XCTAssertTrue(fixture.descriptors.allCloseOnExec)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testIgnoredEntriesConsumeEveryVisitWithoutPreenumeration() throws {
        let fixture = try CollectorPOSIXFixture()
        let inventory = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        defer { inventory.remove() }
        for index in 0..<128 { try fixture.file("ignored-\(index).txt") }
        var rawEntries = 0
        var dotEntries = 0
        var logicalOpens: [String] = []
        var hooks = fixture.hooks
        hooks.afterCursorOpened = { directory, _ in logicalOpens.append(directory) }
        hooks.afterReadEntry = { name in
            if let name {
                rawEntries += 1
                if name == "." || name == ".." { dotEntries += 1 }
            }
        }
        let store = try inventory.open()
        try store.registerRoot(fixture.configuration())
        let scan = try store.beginBootstrap(configuration: fixture.configuration(), scanID: "scan")
        var walker: CollectorBootstrapWalker? = CollectorBootstrapWalker(store: store, enumerator: try fixture.enumerator(hooks: hooks))
        defer { walker = nil }
        let result = try walker!.step(scan: scan, budget: budget(entries: 3))
        XCTAssertEqual(result.outcome, .paused(.budget))
        XCTAssertEqual(result.entriesVisited, 3)
        XCTAssertEqual(result.candidateFiles, 0)
        XCTAssertEqual(rawEntries - dotEntries, 3)
        XCTAssertLessThanOrEqual(dotEntries, 2)
        XCTAssertLessThanOrEqual(rawEntries, 5)
        XCTAssertEqual(logicalOpens, [""])
        XCTAssertTrue(try store.pendingLocators(configuration: fixture.configuration(), limit: 10).isEmpty)
        walker = nil
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testLeafReplacedBySymlinkAfterReaddirCannotBecomeARegularCandidate() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-one.jsonl")
        let outside = fixture.base.appendingPathComponent("outside.jsonl")
        try Data("not source content".utf8).write(to: outside)
        var replaced = false
        var hooks = fixture.hooks
        hooks.afterReadEntry = { name in
            guard name == "rollout-one.jsonl", !replaced else { return }
            replaced = true
            try FileManager.default.removeItem(at: fixture.url("rollout-one.jsonl"))
            try FileManager.default.createSymbolicLink(at: fixture.url("rollout-one.jsonl"), withDestinationURL: outside)
        }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        do {
            // readdir observed a regular entry before the swap. Its d_type
            // cannot authorize a regular candidate after the no-follow stat.
            let entry = try cursor!.next()
            XCTAssertEqual(entry, .symlink("rollout-one.jsonl"))
        } catch {
            XCTAssertEqual(error as? CollectorPOSIXEnumerationError, .directoryContentsChanged)
        }
        XCTAssertTrue(replaced)
        XCTAssertTrue(fixture.descriptors.openedKinds.allSatisfy { $0 == S_IFDIR })
        cursor = nil
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testLogicalDirectoryBudgetIsDistinctFromSafetyOpenatCalls() throws {
        let fixture = try CollectorPOSIXFixture()
        let inventory = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        defer { inventory.remove() }
        try fixture.file("nested/rollout-one.jsonl")
        var logicalOpens: [String] = []
        var hooks = fixture.hooks
        hooks.afterCursorOpened = { directory, _ in logicalOpens.append(directory) }
        let store = try inventory.open()
        try store.registerRoot(fixture.configuration())
        let scan = try store.beginBootstrap(configuration: fixture.configuration(), scanID: "scan")
        var walker: CollectorBootstrapWalker? = CollectorBootstrapWalker(store: store, enumerator: try fixture.enumerator(hooks: hooks))
        defer { walker = nil }
        let first = try walker!.step(scan: scan, budget: budget(directories: 1))
        XCTAssertEqual(first.outcome, .paused(.budget))
        XCTAssertEqual(first.directoriesOpened, 1)
        XCTAssertEqual(logicalOpens, [""])
        XCTAssertGreaterThan(fixture.descriptors.openedCount, 1, "component safety opens are not logical cursor opens")
        XCTAssertLessThanOrEqual(fixture.descriptors.maximumLive, 3)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), ["nested"])
        let second = try walker!.step(scan: scan, budget: budget(directories: 1))
        XCTAssertEqual(second.outcome, .finished)
        XCTAssertEqual(logicalOpens, ["", "nested"])
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testZeroBudgetsDoNotInvokeNativeSourceOperations() throws {
        let fixture = try CollectorPOSIXFixture()
        let inventory = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        defer { inventory.remove() }
        let store = try inventory.open()
        try store.registerRoot(fixture.configuration())
        let scan = try store.beginBootstrap(configuration: fixture.configuration(), scanID: "scan")
        let walker = CollectorBootstrapWalker(store: store, enumerator: try fixture.enumerator())
        for zero in [budget(entries: 0), budget(files: 0), budget(directories: 0), budget(bytes: 0)] {
            XCTAssertEqual(try walker.step(scan: scan, budget: zero).outcome, .paused(.budget))
        }
        XCTAssertEqual(fixture.descriptors.openedCount, 0)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
    }

    func testFreshCursorReplaysDirectoryHeadWithoutSharedDescriptorOffset() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-only.jsonl")
        let enumerator = try fixture.enumerator()
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        let first = try XCTUnwrap(cursor!.next())
        cursor = nil
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        cursor = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        XCTAssertEqual(try cursor!.next(), first)
        XCTAssertNil(try cursor!.next())
        XCTAssertTrue(fixture.descriptors.live.isEmpty, "EOF closes while the cursor remains alive")
    }

    func testSuccessfulEOFAndEarlyDeinitCloseOwnedDescriptorsExactlyOnce() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let enumerator = try fixture.enumerator()
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        XCTAssertFalse(fixture.descriptors.live.isEmpty)
        XCTAssertNil(try cursor!.next())
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        let closedAtEOF = fixture.descriptors.closedCount
        cursor = nil
        XCTAssertEqual(fixture.descriptors.closedCount, closedAtEOF)
        cursor = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        XCTAssertFalse(fixture.descriptors.live.isEmpty)
        cursor = nil
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        XCTAssertEqual(fixture.descriptors.streamCloseCount, 2)
        XCTAssertEqual(fixture.descriptors.openedCount, fixture.descriptors.closedCount)
    }

    func testCancellationBeforeCursorNextClosesItsStream() async throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-one.jsonl")
        let enumerator = try fixture.enumerator()
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        let capturedCursor = try XCTUnwrap(cursor)
        let cancelled = try await Task {
            try withUnsafeCurrentTask { currentTask in
                XCTAssertNotNil(currentTask)
                currentTask?.cancel()
                do { _ = try capturedCursor.next(); return false }
                catch is CancellationError { return true }
            }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        // This is cursor cancellation, not the separately deferred Walker
        // entry-cancellation gate that may skip calling next() altogether.
    }

    func testCancellationAfterEntryReadClosesWithoutEmittingTheEntry() async throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-one.jsonl")
        var cancelledAfterRead = false
        let cancelled = try await Task {
            try withUnsafeCurrentTask { currentTask in
                XCTAssertNotNil(currentTask)
                var hooks = fixture.hooks
                hooks.afterReadEntry = { name in
                    if name == "rollout-one.jsonl" { cancelledAfterRead = true; currentTask?.cancel() }
                }
                let enumerator = try fixture.enumerator(hooks: hooks)
                var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
                defer { cursor = nil }
                do { _ = try cursor!.next(); return false }
                catch is CancellationError {
                    XCTAssertTrue(fixture.descriptors.live.isEmpty)
                    return true
                }
            }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(cancelledAfterRead)
    }

    func testReadDirectoryErrorIsNotEOFAndClosesTheLiveCursor() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        var hooks = fixture.hooks
        hooks.readDirectoryFailure = { EIO }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        XCTAssertThrowsError(try cursor!.next()) { XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .io(.readDirectory, EIO)) }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        XCTAssertThrowsError(try cursor!.next(), "a failed cursor cannot become successful EOF")
    }

    func testStaleErrnoDoesNotTurnSuccessfulEOFIntoAnError() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        var hooks = fixture.hooks
        hooks.beforeReadEntry = { errno = EIO }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        XCTAssertNil(try cursor!.next())
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testCandidateDisappearanceBetweenReaddirAndStatCannotBecomeEOF() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-one.jsonl")
        var removed = false
        var hooks = fixture.hooks
        hooks.afterReadEntry = { name in
            if name == "rollout-one.jsonl", !removed {
                removed = true
                try FileManager.default.removeItem(at: fixture.url("rollout-one.jsonl"))
            }
        }
        let enumerator = try fixture.enumerator(hooks: hooks)
        var cursor: (any CollectorDirectoryCursor)? = try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")
        defer { cursor = nil }
        XCTAssertThrowsError(try cursor!.next()) {
            guard let error = $0 as? CollectorPOSIXEnumerationError else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue([CollectorPOSIXEnumerationError.io(.statEntry, ENOENT), .directoryContentsChanged].contains(error))
        }
        XCTAssertTrue(removed)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testPermissionDeniedRootIsNotAnEmptySuccessfulDirectory() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses the fixture's DAC permission denial")
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        let enumerator = try fixture.enumerator()
        XCTAssertEqual(chmod(fixture.sourceRoot.path, 0), 0)
        defer { XCTAssertEqual(chmod(fixture.sourceRoot.path, 0o700), 0) }
        XCTAssertThrowsError(try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")) {
            guard let error = $0 as? CollectorPOSIXEnumerationError,
                  case .io(_, let code) = error, code == EACCES else {
                return XCTFail("Expected permission denial, received \($0)")
            }
        }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testPartialOpenAndFdopendirFailuresReleaseEveryAcquiredDescriptor() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        var hooks = fixture.hooks
        hooks.beforeOpenComponent = { component in
            if component == fixture.sourceRoot.lastPathComponent { throw CollectorPOSIXFixtureFailure.injected }
        }
        var enumerator = try fixture.enumerator(hooks: hooks)
        XCTAssertThrowsError(try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")) {
            XCTAssertEqual($0 as? CollectorPOSIXFixtureFailure, .injected)
        }
        XCTAssertGreaterThan(fixture.descriptors.openedCount, 0)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        hooks = fixture.hooks
        hooks.directoryStreamFailure = { ENOMEM }
        enumerator = try fixture.enumerator(hooks: hooks)
        XCTAssertThrowsError(try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")) {
            XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .io(.openDirectoryStream, ENOMEM))
        }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        XCTAssertEqual(fixture.descriptors.streamCloseCount, 0, "failed fdopendir never acquired DIR ownership")
        hooks = fixture.hooks
        hooks.afterCursorOpened = { _, _ in throw CollectorPOSIXFixtureFailure.injected }
        enumerator = try fixture.enumerator(hooks: hooks)
        XCTAssertThrowsError(try enumerator.open(configuration: fixture.configuration(), relativeDirectory: "")) {
            XCTAssertEqual($0 as? CollectorPOSIXFixtureFailure, .injected)
        }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        XCTAssertEqual(fixture.descriptors.streamCloseCount, 1, "after transfer, only closedir owns the descriptor")
        XCTAssertEqual(fixture.descriptors.openedCount, fixture.descriptors.closedCount)
    }

    func testDecodedNamesPreserveUTF8BytesAndRejectInvalidUnsafeOrOversizedNames() throws {
        for name in ["é", "e\u{301}", "普通.jsonl", ".", ".."] {
            XCTAssertEqual(Data(try CollectorPOSIXRootEnumerator.decodeEntryName(Data(name.utf8)).utf8), Data(name.utf8))
        }
        for bytes in [Data(), Data([0xFF]), Data([0x61, 0x00, 0x62]), Data("a/b".utf8), Data(repeating: 0x61, count: Int(MAXPATHLEN))] {
            XCTAssertThrowsError(try CollectorPOSIXRootEnumerator.decodeEntryName(bytes)) {
                XCTAssertEqual($0 as? CollectorPOSIXEnumerationError, .invalidEntryName)
            }
        }
    }

    func testObservedFingerprintUsesPhysicalStatAndIsNotCaptureOrPrivacyEvidence() throws {
        let fixture = try CollectorPOSIXFixture()
        defer { fixture.remove() }
        try fixture.file("rollout-one.jsonl", bytes: Data([0xFF]))
        let first = try XCTUnwrap(try fixture.readDirectory().compactMap { entry -> CollectorObservedFile? in
            if case .file(let file) = entry { return file }; return nil
        }.first)
        XCTAssertTrue(first.observedGeneration.hasPrefix("stat-v1:"))
        let generation = try ArchiveCanonicalJSON.decode(ArchiveSourceGeneration.self, from: Data(first.observedGeneration.dropFirst("stat-v1:".count).utf8))
        var info = stat()
        XCTAssertEqual(lstat(fixture.url("rollout-one.jsonl").path, &info), 0)
        XCTAssertEqual(generation.device, Int64(info.st_dev))
        XCTAssertEqual(generation.inode, Int64(info.st_ino))
        XCTAssertEqual(generation.size, Int64(info.st_size))
        XCTAssertEqual(generation.mode, Int64(info.st_mode))
        XCTAssertEqual(generation.mtimeNs, Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
        XCTAssertEqual(generation.ctimeNs, Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
        try fixture.file("rollout-one.jsonl", bytes: Data([0xFF, 0xFE, 0x00]))
        let second = try XCTUnwrap(try fixture.readDirectory().compactMap { entry -> CollectorObservedFile? in
            if case .file(let file) = entry { return file }; return nil
        }.first)
        XCTAssertNotEqual(first.observedGeneration, second.observedGeneration)
        XCTAssertTrue(fixture.descriptors.openedKinds.allSatisfy { $0 == S_IFDIR })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("archive.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("index.sqlite").path))
    }

    func testWalkerNativeReadFailurePreservesReconciliationAndUnfinishedFrontier() throws {
        let fixture = try CollectorPOSIXFixture()
        let inventory = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        defer { inventory.remove() }
        var cursorOpened = false
        var readFailureCalls = 0
        var hooks = fixture.hooks
        hooks.afterCursorOpened = { directory, fd in
            XCTAssertEqual(directory, "")
            XCTAssertNotNil(fixture.descriptors.live[fd])
            cursorOpened = true
        }
        hooks.readDirectoryFailure = {
            readFailureCalls += 1
            XCTAssertTrue(cursorOpened, "the read fault must occur after a directory stream opens")
            return EIO
        }
        let store = try inventory.open()
        try store.registerRoot(fixture.configuration())
        let scan = try store.beginBootstrap(configuration: fixture.configuration(), scanID: "scan")
        let walker = CollectorBootstrapWalker(store: store, enumerator: try fixture.enumerator(hooks: hooks))
        XCTAssertEqual(try walker.step(scan: scan, budget: budget()).outcome, .blocked(.enumerationUnavailable))
        XCTAssertEqual(readFailureCalls, 1, "an earlier open failure must not satisfy native read-failure coverage")
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), [""])
        let state = try XCTUnwrap(store.rootState(rootID: fixture.configuration().rootID))
        XCTAssertEqual(state.completedRevision, 0)
        XCTAssertEqual(state.activeScan, scan)
        XCTAssertGreaterThan(state.requestedRevision, state.completedRevision)
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testWalkerRestartReplaysUnfinishedNativeDirectoryWithoutOpaqueOffsets() throws {
        let fixture = try CollectorPOSIXFixture()
        let inventory = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        defer { inventory.remove() }
        for index in 0..<5 { try fixture.file("rollout-\(index).jsonl") }
        let binding = try fixture.binding()
        var store: CollectorInventoryStore? = try inventory.open(owner: "run-1")
        try store!.registerRoot(fixture.configuration())
        let scan = try store!.beginBootstrap(configuration: fixture.configuration(), scanID: "scan")
        var walker: CollectorBootstrapWalker? = CollectorBootstrapWalker(
            store: store!, enumerator: try CollectorPOSIXRootEnumerator(binding: binding, testHooks: fixture.hooks)
        )
        defer { walker = nil }
        XCTAssertEqual(try walker!.step(scan: scan, budget: budget(entries: 2)).entriesVisited, 2)
        let before = try store!.pendingLocators(configuration: fixture.configuration(), limit: 10)
        XCTAssertEqual(before.count, 2)
        walker = nil
        store = nil
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        let reopened = try inventory.open(owner: "run-2")
        walker = CollectorBootstrapWalker(
            store: reopened, enumerator: try CollectorPOSIXRootEnumerator(binding: binding, testHooks: fixture.hooks)
        )
        XCTAssertEqual(try walker!.step(scan: scan, budget: budget()).outcome, .finished)
        XCTAssertEqual(try reopened.pendingLocators(configuration: fixture.configuration(), limit: 10).count, 5)
        for row in before {
            XCTAssertEqual(try reopened.locator(configuration: fixture.configuration(), relativePath: row.relativePath), row)
        }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
    }

    func testWalkerEntryCancellationClosesHeldStreamAndRetriesFromDirectoryHead() async throws {
        let fixture = try CollectorPOSIXFixture()
        let inventory = try CollectorInventoryTestFixture()
        defer { fixture.remove() }
        defer { inventory.remove() }
        let expected = (0..<3).map { "rollout-\($0).jsonl" }
        for path in expected { try fixture.file(path) }
        var openAttempts = 0
        var readAttempts = 0
        var streamOpens = 0
        var observedNames: [String] = []
        var hooks = fixture.hooks
        hooks.beforeOpenComponent = { _ in openAttempts += 1 }
        hooks.beforeReadEntry = { readAttempts += 1 }
        hooks.afterCursorOpened = { directory, fd in
            XCTAssertEqual(directory, "")
            XCTAssertNotNil(fixture.descriptors.live[fd])
            streamOpens += 1
        }
        hooks.afterReadEntry = { name in
            if let name, name != ".", name != ".." { observedNames.append(name) }
        }
        let store = try inventory.open()
        try store.registerRoot(fixture.configuration())
        let scan = try store.beginBootstrap(configuration: fixture.configuration(), scanID: "scan")
        var walker: CollectorBootstrapWalker? = CollectorBootstrapWalker(store: store, enumerator: try fixture.enumerator(hooks: hooks))
        defer { walker = nil }
        let paused = try walker!.step(scan: scan, budget: budget(entries: 2))
        XCTAssertEqual(paused.outcome, .paused(.budget))
        XCTAssertEqual(paused.entriesVisited, 2)
        XCTAssertEqual(streamOpens, 1)
        XCTAssertEqual(fixture.descriptors.live.count, 1, "the budget pause must retain a real DIR")
        XCTAssertEqual(fixture.descriptors.streamCloseCount, 0)
        let committed = try store.pendingLocators(configuration: fixture.configuration(), limit: 10)
        let frontier = try store.pendingDirectories(scan: scan, limit: 10)
        let root = try XCTUnwrap(store.rootState(rootID: fixture.configuration().rootID))
        let initialNames = observedNames
        let opensBeforeCancellation = openAttempts
        let descriptorsBeforeCancellation = fixture.descriptors.openedCount
        let readsBeforeCancellation = readAttempts
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(frontier, [""])
        XCTAssertEqual(initialNames.count, 2)

        let cancelled = try await Task { [heldWalker = walker!] in
            try withUnsafeCurrentTask { task in
                XCTAssertNotNil(task)
                task?.cancel()
                do { _ = try heldWalker.step(scan: scan, budget: self.budget()); return false }
                catch is CancellationError { return true }
            }
        }.value
        XCTAssertTrue(cancelled)
        withExtendedLifetime(walker!) {
            XCTAssertTrue(fixture.descriptors.live.isEmpty, "the still-owned Walker must release its DIR at entry cancellation")
            XCTAssertEqual(fixture.descriptors.streamCloseCount, 1)
        }
        XCTAssertEqual(openAttempts, opensBeforeCancellation)
        XCTAssertEqual(fixture.descriptors.openedCount, descriptorsBeforeCancellation)
        XCTAssertEqual(readAttempts, readsBeforeCancellation)
        XCTAssertEqual(observedNames, initialNames)
        XCTAssertEqual(try store.pendingDirectories(scan: scan, limit: 10), frontier)
        XCTAssertEqual(try store.pendingLocators(configuration: fixture.configuration(), limit: 10), committed)
        XCTAssertEqual(try store.rootState(rootID: fixture.configuration().rootID), root)

        let finished = try await Task { [heldWalker = walker!] in
            XCTAssertFalse(Task.isCancelled)
            return try heldWalker.step(scan: scan, budget: self.budget()).outcome == .finished
        }.value
        XCTAssertTrue(finished)
        XCTAssertEqual(streamOpens, 2)
        let replayedNames = Array(observedNames.dropFirst(initialNames.count))
        XCTAssertEqual(replayedNames.first, initialNames.first, "retry must reopen the unfinished directory at its head")
        XCTAssertEqual(replayedNames.count, expected.count)
        XCTAssertEqual(Set(replayedNames), Set(expected))
        XCTAssertEqual(Set(try store.pendingLocators(configuration: fixture.configuration(), limit: 10).map(\.relativePath)), Set(expected))
        for row in committed {
            XCTAssertEqual(try store.locator(configuration: fixture.configuration(), relativePath: row.relativePath), row)
        }
        XCTAssertTrue(fixture.descriptors.live.isEmpty)
        XCTAssertEqual(fixture.descriptors.streamCloseCount, 2)
    }

    private func budget(entries: Int = 100, files: Int = 100, directories: Int = 20, bytes: Int = 100_000) -> CollectorBootstrapBudget {
        .init(maxEntriesVisited: entries, maxCandidateFiles: files, maxDirectoryOpens: directories, maxMetadataBytes: bytes)
    }

    private func assertUnsafePathError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? CollectorPOSIXEnumerationError else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
        switch error {
        case .unsafePath, .io(_, ELOOP), .io(_, ENOTDIR): break
        default: XCTFail("Expected a no-follow refusal, received \(error)", file: file, line: line)
        }
    }
}

private enum CollectorPOSIXFixtureFailure: Error, Equatable {
    case injected
    case syscall(Int32)
    case fixtureLimit
}

private final class CollectorPOSIXFixture {
    let base: URL
    let sourceRoot: URL
    let source: SourceName
    let descriptors = CollectorPOSIXDescriptorProbe()

    init(source: SourceName = .codex) throws {
        self.source = source
        // Only the synthetic temp parent is resolved. The adapter itself must
        // not resolve symlinks in any configured root.
        guard let physicalTemp = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CollectorPOSIXFixtureFailure.syscall(errno)
        }
        defer { free(physicalTemp) }
        base = URL(fileURLWithPath: String(cString: physicalTemp), isDirectory: true)
            .appendingPathComponent("cp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        sourceRoot = base.appendingPathComponent(source == .claudeCode ? "projects" : "sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }

    func configuration(
        rootID: String = "fixture-root",
        source: SourceName? = nil,
        revision: Int64 = 1,
        path: String? = nil
    ) -> CollectorRootConfiguration {
        .init(rootID: rootID, source: source ?? self.source, rootPath: path ?? sourceRoot.path, revision: revision)
    }

    func identity() throws -> CollectorPOSIXDirectoryIdentity {
        var info = stat()
        guard lstat(sourceRoot.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CollectorPOSIXFixtureFailure.syscall(errno)
        }
        return .init(
            device: Int64(info.st_dev), inode: Int64(info.st_ino), generation: info.st_gen,
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }

    func binding() throws -> CollectorPOSIXRootBinding {
        .init(configuration: configuration(), expectedIdentity: try identity())
    }

    var hooks: CollectorPOSIXRootEnumeratorTestHooks {
        .init(
            didOpenDescriptor: { [descriptors] in descriptors.opened($0) },
            didCloseDescriptor: { [descriptors] in descriptors.closed($0, viaDirectoryStream: $1) }
        )
    }

    func enumerator(
        configuration: CollectorRootConfiguration? = nil,
        identity: CollectorPOSIXDirectoryIdentity? = nil,
        hooks: CollectorPOSIXRootEnumeratorTestHooks? = nil
    ) throws -> CollectorPOSIXRootEnumerator {
        try CollectorPOSIXRootEnumerator(
            binding: .init(configuration: configuration ?? self.configuration(), expectedIdentity: try identity ?? self.identity()),
            testHooks: hooks ?? self.hooks
        )
    }

    func url(_ relativePath: String) -> URL { sourceRoot.appendingPathComponent(relativePath) }

    func file(_ relativePath: String, bytes: Data = Data("synthetic fixture".utf8)) throws {
        let path = url(relativePath)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: path)
    }

    func replaceRoot() throws {
        try FileManager.default.moveItem(at: sourceRoot, to: base.appendingPathComponent("retired-root"))
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func replaceDirectory(_ relativePath: String) throws {
        let path = url(relativePath)
        try FileManager.default.moveItem(at: path, to: base.appendingPathComponent("retired-directory"))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func advanceDirectoryTimestamp() throws {
        var info = stat()
        guard lstat(sourceRoot.path, &info) == 0 else { throw CollectorPOSIXFixtureFailure.syscall(errno) }
        var times = [info.st_atimespec, timespec(tv_sec: info.st_mtimespec.tv_sec + 2, tv_nsec: info.st_mtimespec.tv_nsec)]
        let result = times.withUnsafeMutableBufferPointer { utimensat(AT_FDCWD, sourceRoot.path, $0.baseAddress!, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { throw CollectorPOSIXFixtureFailure.syscall(errno) }
    }

    func readDirectory(
        enumerator: CollectorPOSIXRootEnumerator? = nil,
        relativeDirectory: String = ""
    ) throws -> [CollectorDirectoryEntry] {
        let sourceEnumerator = try enumerator ?? self.enumerator()
        var cursor: (any CollectorDirectoryCursor)? = try sourceEnumerator.open(configuration: configuration(), relativeDirectory: relativeDirectory)
        defer { cursor = nil }
        var entries: [CollectorDirectoryEntry] = []
        while let entry = try cursor!.next() {
            entries.append(entry)
            guard entries.count <= 256 else { throw CollectorPOSIXFixtureFailure.fixtureLimit }
        }
        return entries
    }

    func enumerateSelectedFiles() throws -> [String] {
        let enumerator = try self.enumerator()
        var directories = [""]
        var visited = 0
        var files: [String] = []
        while !directories.isEmpty {
            let directory = directories.removeFirst()
            visited += 1
            guard visited <= 128 else { throw CollectorPOSIXFixtureFailure.fixtureLimit }
            for entry in try readDirectory(enumerator: enumerator, relativeDirectory: directory) {
                switch entry {
                case .directory(let path): directories.append(path)
                case .file(let file): files.append(file.relativePath)
                case .ignored, .symlink: break
                }
            }
        }
        return files
    }

    func remove() {
        guard descriptors.live.isEmpty else {
            XCTFail("Preserving synthetic fixture because source descriptors remain open: \(base.path)")
            return
        }
        do { try FileManager.default.removeItem(at: base) }
        catch { XCTFail("Could not remove synthetic fixture: \(error)") }
    }
}

// Calls are serialized by the fixture's cursor owner. No global fd count or
// production-path observation is used. Closed-fd checks tolerate numeric reuse
// only when the reused descriptor identifies a different physical object.
private final class CollectorPOSIXDescriptorProbe {
    struct Identity: Equatable { let device: dev_t; let inode: ino_t }
    private(set) var live: [Int32: Identity] = [:]
    private(set) var openedCount = 0
    private(set) var closedCount = 0
    private(set) var streamCloseCount = 0
    private(set) var maximumLive = 0
    private(set) var openedKinds: [mode_t] = []
    private(set) var openedPaths: [String] = []
    private(set) var allCloseOnExec = true

    func opened(_ fd: Int32) {
        var info = stat()
        XCTAssertEqual(fstat(fd, &info), 0)
        XCTAssertNil(live[fd], "descriptor was registered twice without closing")
        live[fd] = Identity(device: info.st_dev, inode: info.st_ino)
        openedCount += 1
        maximumLive = max(maximumLive, live.count)
        openedKinds.append(info.st_mode & S_IFMT)
        allCloseOnExec = allCloseOnExec && fcntl(fd, F_GETFD) & FD_CLOEXEC != 0
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
        XCTAssertEqual(result, 0)
        if result == 0 { openedPaths.append(String(cString: path)) }
    }

    func closed(_ fd: Int32, viaDirectoryStream: Bool) {
        let expected = live.removeValue(forKey: fd)
        XCTAssertNotNil(expected, "unowned descriptor closed or closed twice")
        closedCount += 1
        if viaDirectoryStream { streamCloseCount += 1 }
        var info = stat()
        if fstat(fd, &info) == 0 {
            XCTAssertNotEqual(Identity(device: info.st_dev, inode: info.st_ino), expected, "closed descriptor still owns the same object")
        } else {
            XCTAssertEqual(errno, EBADF)
        }
    }
}

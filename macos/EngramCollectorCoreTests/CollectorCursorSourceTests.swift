import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EngramCollectorCore

/// Modern `.cursor` chats/projects discovery only.
/// Legacy `state.vscdb?composer=` remains explicitly pending beside this foundation.
final class CollectorCursorSourceTests: XCTestCase {
    func testModernObservationMapsStoreAndAuxiliaryPathsToPairedTranscriptSnapshot() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "bridge")
        try f.writeFile(URL(fileURLWithPath: store.path + "-wal"), "wal")
        try f.writeFile(URL(fileURLWithPath: store.path + "-shm"), "shm")
        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "{}")
        let transcript = try f.writeTranscript(project: "proj", id: "bridge")
        let expected = "projects/proj/agent-transcripts/bridge/bridge.jsonl"
        let observation = try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/ws/bridge/store.db")
        XCTAssertEqual(observation.snapshot.entrypointRelativePath, expected)
        XCTAssertEqual(observation.generation, observation.snapshot.present.first { $0.relativePath == expected }?.generation)
        XCTAssertEqual(observation.snapshot.present.map(\.relativePath), ["chats/ws/bridge/meta.json",
            "chats/ws/bridge/store.db", "chats/ws/bridge/store.db-wal", expected])
        XCTAssertEqual(observation.snapshot.absentRelativePaths, [])
        for path in ["chats/ws/bridge/store.db", "chats/ws/bridge/store.db-wal", "chats/ws/bridge/meta.json", expected] {
            XCTAssertEqual(CollectorCursorSource.sessionOwning(path), "bridge")
            XCTAssertEqual(try CollectorCursorSource.observe(rootPath: f.root.path, primaryRelative: path).snapshot,
                observation.snapshot)
        }
        try FileManager.default.removeItem(at: transcript)
        let storeOnly = try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/ws/bridge/store.db")
        XCTAssertEqual(storeOnly.snapshot.entrypointRelativePath, "chats/ws/bridge/store.db")
    }

    func testModernObservationRetainsOnlyMissingReplaySlotsAndRejectsUnrelatedPaths() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "bridge")
        let observation = try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/ws/bridge/store.db")
        XCTAssertEqual(observation.snapshot.absentRelativePaths,
            ["chats/ws/bridge/meta.json", "chats/ws/bridge/store.db-wal"])
        for path in ["chats/ws/bridge/store.db-shm", "chats/ws/bridge/store.db-journal", "chats/ws/bridge/notes.txt",
            "chats/.hidden/bridge/store.db", "projects/proj/agent-transcripts/bridge/wrong.jsonl", "../store.db"] {
            XCTAssertNil(CollectorCursorSource.sessionOwning(path), path)
            XCTAssertThrowsError(try CollectorCursorSource.observe(rootPath: f.root.path, primaryRelative: path), path)
        }
        XCTAssertThrowsError(try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/other/bridge/store.db"), "a matching ID is not authority for an unobserved workspace")
    }

    func testObserveSkipsUnrelatedSessionPayloadAndStillRefusesDuplicateIDs_repro() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "keep")
        try f.writeTranscript(project: "proj", id: "keep")
        // Recognized payloads whose type is not a regular file. Full-tree
        // discoverModern stats every session directory and refuses; per-ID
        // observe must not enter these unrelated IDs.
        try f.makeChatsSession(workspace: "ws", id: "poison-store")
        XCTAssertEqual(mkfifo(f.chatsSession(workspace: "ws", id: "poison-store").appendingPathComponent("store.db").path, 0o600), 0)
        try f.makeTranscriptSession(project: "proj", id: "poison-tr")
        XCTAssertEqual(mkfifo(f.transcriptURL(project: "proj", id: "poison-tr").path, 0o600), 0)
        let observed = try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/ws/keep/store.db")
        XCTAssertEqual(observed.session.nativeSessionID, "keep")
        XCTAssertEqual(observed.snapshot.entrypointRelativePath,
            "projects/proj/agent-transcripts/keep/keep.jsonl")
        XCTAssertEqual(try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "projects/proj/agent-transcripts/keep/keep.jsonl").snapshot, observed.snapshot)
        assertRefused { try f.discover() }

        func assertAmbiguous(_ work: () throws -> CollectorCursorSource.SessionObservation) {
            XCTAssertThrowsError(try work()) {
                guard case CollectorCursorSource.DiscoveryError.ambiguousSession = $0 else {
                    return XCTFail("duplicate matching IDs must stay ambiguousSession: \($0)")
                }
            }
        }
        let stores = try CursorFixture(); defer { stores.remove() }
        try stores.writeStore(workspace: "ws-a", id: "dup")
        try stores.writeStore(workspace: "ws-b", id: "dup")
        assertAmbiguous {
            try CollectorCursorSource.observe(rootPath: stores.root.path, primaryRelative: "chats/ws-a/dup/store.db")
        }
        assertAmbiguous {
            try CollectorCursorSource.observe(rootPath: stores.root.path, primaryRelative: "chats/ws-b/dup/store.db")
        }
        assertRefused { try stores.discover() }

        let transcripts = try CursorFixture(); defer { transcripts.remove() }
        try transcripts.writeTranscript(project: "p-a", id: "dup")
        try transcripts.writeTranscript(project: "p-b", id: "dup")
        assertAmbiguous {
            try CollectorCursorSource.observe(rootPath: transcripts.root.path,
                primaryRelative: "projects/p-a/agent-transcripts/dup/dup.jsonl")
        }
        assertAmbiguous {
            try CollectorCursorSource.observe(rootPath: transcripts.root.path,
                primaryRelative: "projects/p-b/agent-transcripts/dup/dup.jsonl")
        }
        assertRefused { try transcripts.discover() }
    }

    func testObserveSelectsExactUTF8SessionNamesWithoutCaseOrNormalizationFolding_repro() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws-a", id: "keep")
        try f.writeStore(workspace: "ws-b", id: "KEEP")
        XCTAssertEqual(try f.names(in: f.root.appendingPathComponent("chats/ws-a")), ["keep"])
        XCTAssertEqual(try f.names(in: f.root.appendingPathComponent("chats/ws-b")), ["KEEP"])
        try XCTSkipUnless(fstatatFolds(parent: f.root.appendingPathComponent("chats/ws-b"), requested: "keep"),
            "this regression needs a folding volume so openat(keep) can land on KEEP")

        let lower = try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/ws-a/keep/store.db")
        XCTAssertEqual(lower.session.nativeSessionID, "keep")
        XCTAssertEqual(lower.session.storeRelativePath, "chats/ws-a/keep/store.db")
        XCTAssertFalse(lower.session.present.contains { $0.relativePath.contains("KEEP") })
        XCTAssertEqual(try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/ws-b/KEEP/store.db").session.nativeSessionID, "KEEP")
        XCTAssertThrowsError(try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: "chats/ws-b/keep/store.db"),
            "a folded lookup is not authority for a differently spelled directory")
        XCTAssertEqual(try f.discover().map(\.nativeSessionID), ["KEEP", "keep"])

        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertFalse(nfc.utf8.elementsEqual(nfd.utf8))
        try f.writeTranscript(project: "p-fold", id: nfc)
        let onDisk = try XCTUnwrap(try f.names(in: f.root.appendingPathComponent("projects/p-fold/agent-transcripts")).first)
        let folded = onDisk.utf8.elementsEqual(nfc.utf8) ? nfd : nfc
        XCTAssertFalse(onDisk.utf8.elementsEqual(folded.utf8))
        try XCTSkipUnless(fstatatFolds(parent: f.root.appendingPathComponent("projects/p-fold/agent-transcripts"),
            requested: folded), "openat of a canonically equivalent ID must resolve the on-disk directory")
        let exact = try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: f.transcriptRelative(project: "p-fold", id: onDisk))
        XCTAssertTrue(exact.session.nativeSessionID.utf8.elementsEqual(onDisk.utf8))
        XCTAssertThrowsError(try CollectorCursorSource.observe(rootPath: f.root.path,
            primaryRelative: f.transcriptRelative(project: "p-fold", id: folded)),
            "normalization-equivalent spelling must not inherit the on-disk session")
    }

    func testReservationSnapshotValidatesPairedPrimaryAndAllCapturedMembers() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "reserved")
        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "{}")
        try f.writeTranscript(project: "project", id: "reserved")
        let observed = try XCTUnwrap(try f.discover().first)
        let sealed = try f.capture(observed)
        let primary = try XCTUnwrap(observed.transcriptRelativePath)
        let snapshot = CollectorDependencySnapshot(entrypointRelativePath: primary,
            present: sealed.files.map { .init(relativePath: $0.relativePath, generation: $0.generation) },
            absentRelativePaths: [try XCTUnwrap(observed.storeRelativePath) + "-wal"])
        XCTAssertNoThrow(try CollectorCursorSource.requireValidSnapshot(snapshot, entrypoint: primary))
        let archive = f.base.appendingPathComponent("archive")
        let machine = "11111111-2222-3333-4444-555555555555"
        let cas = try ImmutableArchiveCAS(root: archive)
        let catalog = try ArchiveCatalog(root: archive, machineID: machine)
        try catalog.migrate(); defer { try? catalog.close() }
        let captured = try CollectorCursorSource.persistModern(sealed, machineID: machine, cas: cas, catalog: catalog)
        try FileManager.default.removeItem(at: f.root)
        XCTAssertTrue(CollectorCursorSource.matchesReservedSnapshot(snapshot, manifest: captured.manifest))
        let wrongPrimary = try XCTUnwrap(observed.storeRelativePath)
        let variants = [
            CollectorDependencySnapshot(entrypointRelativePath: wrongPrimary, present: snapshot.present,
                absentRelativePaths: snapshot.absentRelativePaths),
            CollectorDependencySnapshot(entrypointRelativePath: primary, present: Array(snapshot.present.reversed()),
                absentRelativePaths: snapshot.absentRelativePaths),
            CollectorDependencySnapshot(entrypointRelativePath: primary,
                present: snapshot.present.filter { !$0.relativePath.hasSuffix("meta.json") },
                absentRelativePaths: snapshot.absentRelativePaths),
            CollectorDependencySnapshot(entrypointRelativePath: primary, present: snapshot.present,
                absentRelativePaths: snapshot.absentRelativePaths + [wrongPrimary + "-shm"]),
            CollectorDependencySnapshot(entrypointRelativePath: primary, present: snapshot.present + [snapshot.present[0]],
                absentRelativePaths: snapshot.absentRelativePaths),
        ]
        for variant in variants {
            XCTAssertThrowsError(try CollectorCursorSource.requireValidSnapshot(variant, entrypoint: variant.entrypointRelativePath))
            XCTAssertFalse(CollectorCursorSource.matchesReservedSnapshot(variant, manifest: captured.manifest))
        }
        // Same shape, different auxiliary generation must fail the sealed match.
        let meta = try XCTUnwrap(snapshot.present.firstIndex { $0.relativePath.hasSuffix("meta.json") })
        var changed = snapshot.present
        changed[meta] = .init(relativePath: changed[meta].relativePath, generation: try XCTUnwrap(snapshot.present.first { $0.relativePath == primary }).generation)
        let changedSnapshot = CollectorDependencySnapshot(entrypointRelativePath: primary,
            present: changed, absentRelativePaths: snapshot.absentRelativePaths)
        XCTAssertNoThrow(try CollectorCursorSource.requireValidSnapshot(changedSnapshot, entrypoint: primary))
        XCTAssertFalse(CollectorCursorSource.matchesReservedSnapshot(changedSnapshot, manifest: captured.manifest))
    }

    func testReservationSnapshotAcceptsStoreOnlyAndTranscriptOnlyClosedShapes() throws {
        for storeOnly in [false, true] {
            let f = try CursorFixture(); defer { f.remove() }
            if storeOnly { try f.writeStore(workspace: "ws", id: "single") }
            else { try f.writeTranscript(project: "project", id: "single") }
            let observed = try XCTUnwrap(try f.discover().first)
            let sealed = try f.capture(observed)
            let primary = try XCTUnwrap(observed.transcriptRelativePath ?? observed.storeRelativePath)
            let absent = observed.absentRelativePaths.filter { $0.hasSuffix("store.db-wal") || $0.hasSuffix("/meta.json") }
            let snapshot = CollectorDependencySnapshot(entrypointRelativePath: primary,
                present: sealed.files.map { .init(relativePath: $0.relativePath, generation: $0.generation) },
                absentRelativePaths: absent)
            XCTAssertNoThrow(try CollectorCursorSource.requireValidSnapshot(snapshot, entrypoint: primary))
        }
    }

    func testCaptureDeadlineStopsInitialDirectoryEnumeration() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeTranscript(project: "project", id: "clock")
        let observed = try XCTUnwrap(try f.discover().first)
        // An expired walk must stop before inspecting this later unsafe input.
        try f.makeChatsSession(workspace: "ws", id: "unsafe")
        XCTAssertEqual(mkfifo(f.chatsSession(workspace: "ws", id: "unsafe").appendingPathComponent("store.db").path, 0o600), 0)
        var ticks = 0
        XCTAssertThrowsError(try f.capture(observed, testHooks: .init(uptimeNanoseconds: {
            ticks += 1
            return ticks < 6 ? 0 : 6_000_000_000
        }))) {
            XCTAssertEqual($0 as? CollectorSQLiteSnapshotError, .exceededBudget)
        }
    }

    func testCaptureDeadlineStopsFinalDirectoryEnumeration() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let transcript = try f.writeTranscript(project: "project", id: "clock")
        let observed = try XCTUnwrap(try f.discover().first)
        var now: UInt64 = 0
        XCTAssertThrowsError(try f.capture(observed, testHooks: .init(beforeFinalValidation: {
            now = 6_000_000_000
            try FileManager.default.removeItem(at: transcript)
            XCTAssertEqual(mkfifo(transcript.path, 0o600), 0)
        }, uptimeNanoseconds: { now }))) {
            XCTAssertEqual($0 as? CollectorSQLiteSnapshotError, .exceededBudget)
        }
    }

    func testPayloadDisappearanceIsSourceChange() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "vanish")
        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "{}")
        let transcript = try f.writeTranscript(project: "project", id: "vanish")
        let observed = try XCTUnwrap(try f.discover().first)
        XCTAssertThrowsError(try f.capture(observed, testHooks: .init(afterFileRead: { path in
            if path.hasSuffix("meta.json") { try FileManager.default.removeItem(at: transcript) }
        }))) {
            XCTAssertTrue($0 is CollectorCursorSource.DiscoveryError)
            guard case CollectorCursorSource.DiscoveryError.sourceChanged = $0 else {
                return XCTFail("Disappeared payload must be retried as a changed source: \($0)")
            }
        }
    }

    func testRawPairValidatorExpiresWhenTheLeaseScopeEnds() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "scope")
        let staging = f.base.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let escaped = try CollectorSQLiteSnapshotLease.withSnapshot(root: store.deletingLastPathComponent(),
            databaseName: "store.db", stagingParent: staging) { snapshot in
                try snapshot.validateRawPair()
                return snapshot
            }
        XCTAssertThrowsError(try escaped.validateRawPair()) {
            XCTAssertEqual($0 as? CollectorSQLiteSnapshotError, .unavailable)
        }
    }

    func testModernCaptureCancellationAndDeadlineOverflowDoNotReturnBytes() async throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "cancel")
        let observed = try XCTUnwrap(try f.discover().first)
        assertRefused { try f.capture(observed, budget: .init(maximumLeaseMilliseconds: Int.max)) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try f.capture(observed)
        }
        do { _ = try await task.value; XCTFail("cancelled capture returned bytes") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testModernCapturePreservesExactRawPairJSONLAndMetadataWithoutSHM() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "raw")
        let wal = URL(fileURLWithPath: store.path + "-wal")
        let meta = store.deletingLastPathComponent().appendingPathComponent("meta.json")
        try f.writeFile(wal, Data([0, 255, 128, 13, 10]))
        try f.writeFile(meta, Data([255, 13, 10]))
        try f.writeFile(URL(fileURLWithPath: store.path + "-shm"), "SHM-SECRET")
        let transcript = try f.writeTranscript(project: "project", id: "raw")
        try f.writeFile(transcript, Data([0, 255, 10]))
        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("notes.txt"), "UNRELATED-SECRET")
        let observed = try XCTUnwrap(try f.discover().first)
        let originals = try Dictionary(uniqueKeysWithValues: [store, wal, meta, transcript].map {
            (String($0.path.dropFirst(f.root.path.count + 1)), try Data(contentsOf: $0))
        })
        let capture = try f.capture(observed)
        XCTAssertEqual(capture.session, observed)
        XCTAssertEqual(capture.files.map(\.relativePath), originals.keys.sorted())
        for file in capture.files {
            XCTAssertEqual(file.bytes, originals[file.relativePath])
            XCTAssertEqual(file.generation, observed.present.first { $0.relativePath == file.relativePath }?.generation)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(file.relativePath)), file.bytes)
        }
        XCTAssertFalse(capture.files.contains { $0.relativePath.hasSuffix("-shm") || $0.relativePath.hasSuffix("-journal") })
        XCTAssertFalse(capture.files.contains { $0.bytes.range(of: Data("SECRET".utf8)) != nil })
    }

    func testModernCaptureHandlesTranscriptOnlyAndKnownMissingMetadata() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let transcript = try f.writeTranscript(project: "project", id: "transcript-only")
        let first = try XCTUnwrap(try f.discover().first)
        let captured = try f.capture(first)
        XCTAssertNil(captured.session.storeRelativePath)
        XCTAssertEqual(captured.files.map(\.relativePath), [f.transcriptRelative(project: "project", id: "transcript-only")])
        XCTAssertEqual(captured.files.first?.bytes, try Data(contentsOf: transcript))
        try f.writeStore(workspace: "ws", id: "store-only")
        let store = try XCTUnwrap(try f.discover().first { $0.nativeSessionID == "store-only" })
        let storeCapture = try f.capture(store)
        XCTAssertEqual(storeCapture.files.map(\.relativePath), [f.storeRelative(workspace: "ws", id: "store-only")])
        XCTAssertTrue(storeCapture.session.absentRelativePaths.contains("chats/ws/store-only/meta.json"))
    }

    func testModernCaptureBudgetCoversEveryPayloadMemberTogether() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "budget")
        try f.writeFile(URL(fileURLWithPath: store.path + "-wal"), "wal")
        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "meta")
        try f.writeTranscript(project: "project", id: "budget")
        let observed = try XCTUnwrap(try f.discover().first)
        let total = observed.present.filter { !$0.relativePath.hasSuffix("-shm") }.reduce(Int64(0)) { $0 + $1.generation.size }
        XCTAssertEqual(try f.capture(observed, maximumByteCount: total).files.reduce(Int64(0)) { $0 + Int64($1.bytes.count) }, total)
        assertRefused { try f.capture(observed, maximumByteCount: total - 1) }
        assertRefused { try f.capture(observed, maximumByteCount: -1) }
        assertRefused { try f.capture(observed, maximumDirectoryEntries: 1) }
        assertRefused { try f.capture(observed, budget: .init(maximumLeaseMilliseconds: -1)) }
    }

    func testModernCaptureRefusesStaleInputAndSourceMutationAfterReading() throws {
        for change in ["stale", "meta", "transcript", "root"] {
            let f = try CursorFixture(); defer { f.remove() }
            let store = try f.writeStore(workspace: "ws", id: "fence")
            let transcript = try f.writeTranscript(project: "project", id: "fence")
            let observed = try XCTUnwrap(try f.discover().first)
            if change == "stale" { try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "stale") }
            assertRefused {
                try f.capture(observed, testHooks: .init(beforeFinalValidation: {
                    switch change {
                    case "meta": try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "added")
                    case "transcript": try f.writeFile(transcript, "changed")
                    case "root": try f.replaceDirectory(f.root) { try f.writeStore(workspace: "ws", id: "fence") }
                    default: break
                    }
                }))
            }
        }
    }

    func testModernCaptureRefusesPrivatePairMutationWhileReading() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "private")
        try f.writeFile(URL(fileURLWithPath: store.path + "-wal"), "original-wal")
        let observed = try XCTUnwrap(try f.discover().first)
        var privateURL: URL?
        assertRefused {
            try f.capture(observed, testHooks: .init(snapshot: .init(beforeSnapshotUse: { privateURL = $0 }),
                afterFileRead: { path in
                    if path.hasSuffix("/store.db") {
                        try f.writeFile(URL(fileURLWithPath: try XCTUnwrap(privateURL).path + "-wal"), "replaced-wal")
                    }
                }))
        }
    }

    func testModernCaptureIgnoresUnrelatedWritesButRefusesRecognizedUnsafeFiles() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "selected")
        let observed = try XCTUnwrap(try f.discover().first)
        let captured = try f.capture(observed, testHooks: .init(beforeFinalValidation: {
            try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("scratch"), "unrelated")
        }))
        XCTAssertEqual(captured.files.map(\.relativePath), [f.storeRelative(workspace: "ws", id: "selected")])
        XCTAssertEqual(mkfifo((store.path + "-wal"), 0o600), 0)
        assertRefused { try f.capture(observed) }
    }

    func testPrivatePairCannotChangeBetweenStagingAndConsumerAdmission() throws {
        for change in ["main", "wal", "wal-link", "wal-added", "shm-link", "journal"] {
            let f = try CursorFixture(); defer { f.remove() }
            let store = try f.writeStore(workspace: "ws", id: "private-fence")
            if change != "wal-added" { try f.writeFile(URL(fileURLWithPath: store.path + "-wal"), "original-wal") }
            let staging = f.base.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            assertRefused {
                try CollectorSQLiteSnapshotLease.withSnapshot(root: store.deletingLastPathComponent(), databaseName: "store.db",
                    stagingParent: staging, testHooks: .init(beforeSnapshotUse: { privateURL in
                        switch change {
                        case "main": try f.writeFile(privateURL, "tampered-private-main")
                        case "wal", "wal-added": try f.writeFile(URL(fileURLWithPath: privateURL.path + "-wal"), "tampered-wal")
                        case "wal-link":
                            let wal = URL(fileURLWithPath: privateURL.path + "-wal")
                            try FileManager.default.removeItem(at: wal)
                            try FileManager.default.createSymbolicLink(at: wal, withDestinationURL: store)
                        case "shm-link":
                            try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: privateURL.path + "-shm"), withDestinationURL: store)
                        default: try f.writeFile(URL(fileURLWithPath: privateURL.path + "-journal"), "unexpected-journal")
                        }
                    })) { _ in XCTFail("private pair changed before admission: \(change)") }
            }
            XCTAssertEqual(try Data(contentsOf: store), f.invalidStoreBytes)
            XCTAssertTrue(try f.names(in: staging).isEmpty)
        }
    }

    func testModernStoreLeaseReadsCommittedWalAfterOriginalRemoval() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "leased")
        try FileManager.default.removeItem(at: store)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &writer), SQLITE_OK)
        defer { if let writer { sqlite3_close(writer) } }
        XCTAssertEqual(sqlite3_exec(writer,
            "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('0','committed-cursor');",
            nil, nil, nil), SQLITE_OK)
        let observed = try XCTUnwrap(try f.discover().first)
        let staging = f.base.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var privateURL: URL?
        try CollectorCursorSource.withModernStoreSnapshot(rootPath: f.root.path, session: observed, stagingParent: staging) { snapshot in
            privateURL = snapshot.privateDatabaseURL
            XCTAssertEqual(snapshot.databaseGeneration, observed.present.first { $0.relativePath.hasSuffix("/store.db") }?.generation)
            XCTAssertEqual(snapshot.walGeneration, observed.present.first { $0.relativePath.hasSuffix("/store.db-wal") }?.generation)
            if let writer { XCTAssertEqual(sqlite3_close(writer), SQLITE_OK) }; writer = nil
            try FileManager.default.removeItem(at: f.root)
            var reader: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(snapshot.privateDatabaseURL.path, &reader, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil), SQLITE_OK)
            defer { if let reader { sqlite3_close(reader) } }
            var query: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(reader, "SELECT value FROM meta WHERE key='0'", -1, &query, nil), SQLITE_OK)
            defer { sqlite3_finalize(query) }
            XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
            XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(query, 0))), "committed-cursor")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(privateURL).path))
        XCTAssertTrue(try f.names(in: staging).isEmpty)
    }

    func testModernStoreLeaseRefusesStaleOrForgedDependenciesAndTranscriptOnly() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "leased")
        let expected = try XCTUnwrap(try f.discover().first)
        let staging = f.base.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "changed")
        assertRefused {
            try CollectorCursorSource.withModernStoreSnapshot(rootPath: f.root.path, session: expected, stagingParent: staging) { _ in XCTFail("stale metadata") }
        }
        let current = try XCTUnwrap(try f.discover().first)
        let forged = CollectorCursorSource.ModernSession(nativeSessionID: "other", storeRelativePath: current.storeRelativePath,
            transcriptRelativePath: current.transcriptRelativePath, present: current.present, absentRelativePaths: current.absentRelativePaths)
        assertRefused {
            try CollectorCursorSource.withModernStoreSnapshot(rootPath: f.root.path, session: forged, stagingParent: staging) { _ in XCTFail("forged identity") }
        }
        try f.writeTranscript(project: "project", id: "transcript-only")
        let transcript = try XCTUnwrap(try f.discover().first { $0.nativeSessionID == "transcript-only" })
        assertRefused {
            try CollectorCursorSource.withModernStoreSnapshot(rootPath: f.root.path, session: transcript, stagingParent: staging) { _ in XCTFail("no store") }
        }
        XCTAssertTrue(try f.names(in: staging).isEmpty)
    }

    func testModernStoreLeaseFencesMetadataAndTranscriptChangesWhileCopying() throws {
        for transcriptChange in [false, true] {
            let f = try CursorFixture(); defer { f.remove() }
            let store = try f.writeStore(workspace: "ws", id: "leased")
            let transcript = try f.writeTranscript(project: "project", id: "leased")
            let expected = try XCTUnwrap(try f.discover().first)
            let staging = f.base.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            assertRefused {
                try CollectorCursorSource.withModernStoreSnapshot(rootPath: f.root.path, session: expected, stagingParent: staging,
                    testHooks: .init(afterPrivateMainCopy: {
                        try f.writeFile(transcriptChange ? transcript : store.deletingLastPathComponent().appendingPathComponent("meta.json"), "changed during copy")
                    })) { _ in XCTFail("dependency drift") }
            }
            XCTAssertTrue(try f.names(in: staging).isEmpty)
        }
    }

    func testNativeSkippedSymlinkChildrenDoNotBlockUnrelatedSessions() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "keep")
        for directory in [f.root.appendingPathComponent("chats"), store.deletingLastPathComponent().deletingLastPathComponent()] {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("scratch.link"),
                withDestinationURL: store)
        }
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("chats/linked-workspace"),
            withDestinationURL: store.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(try f.discover().map(\.nativeSessionID), ["keep"],
            "native child enumeration skips links without following them; selected primary/sidecar links still refuse")
    }

    func testEntryBudgetCoversBothValidationPassesTogether() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "budget")
        // Four entries: chats, workspace, session, store.db. Validation revisits all four.
        assertRefused { try f.discover(maximumDirectoryEntries: 4) }
        XCTAssertEqual(try f.discover(maximumDirectoryEntries: 8).map(\.nativeSessionID), ["budget"])
    }

    func testDuplicatedDirectoryDescriptorIsNeverInheritableBeforeFdopendir() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let original = open(f.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(original, 0)
        guard original >= 0 else { return }
        defer { _ = Darwin.close(original) }
        let copied = try CollectorCursorSource.duplicateDirectoryDescriptor(original)
        defer { _ = Darwin.close(copied) }
        XCTAssertNotEqual(copied, original)
        XCTAssertNotEqual(fcntl(copied, F_GETFD) & FD_CLOEXEC, 0,
            "dup clears CLOEXEC before fdopendir restores it; concurrent exec must not inherit the directory")
        var originalInfo = stat(), copiedInfo = stat()
        XCTAssertEqual(fstat(original, &originalInfo), 0)
        XCTAssertEqual(fstat(copied, &copiedInfo), 0)
        XCTAssertEqual(originalInfo.st_ino, copiedInfo.st_ino)
        XCTAssertEqual(originalInfo.st_dev, copiedInfo.st_dev)
    }

    func testNativeHiddenDirectoryExclusionsDoNotCreateCollectedSessions() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "visible", id: "keep")
        try f.writeStore(workspace: ".hidden-workspace", id: "hidden-store")
        try f.writeStore(workspace: "visible", id: ".hidden-session")
        try f.writeTranscript(project: ".hidden-project", id: "hidden-transcript")
        try f.writeTranscript(project: "visible", id: ".hidden-session")
        let flagged = try f.writeStore(workspace: "flagged-workspace", id: "hidden-flag")
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(chflags(flagged.path, UInt32(UF_HIDDEN)), 0)
        XCTAssertEqual(try f.discover().map(\.nativeSessionID), ["keep"],
            "native directChildren skips dot-hidden and filesystem-hidden child directories")
    }

    func testStoreOnlyObservesSidecarAbsenceWithoutFabricatingTranscriptOrOpeningBytes() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "sess-store")
        try f.writeFile(f.root.appendingPathComponent("state.vscdb"), f.invalidStoreBytes)
        let beforeStore = try Data(contentsOf: store)
        let beforeLegacy = try Data(contentsOf: f.root.appendingPathComponent("state.vscdb"))

        let sessions = try f.discover()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sessions.map(\.nativeSessionID), ["sess-store"])
        XCTAssertEqual(session.storeRelativePath, f.storeRelative(workspace: "ws", id: "sess-store"))
        XCTAssertNil(session.transcriptRelativePath)
        XCTAssertEqual(session.present.map(\.relativePath), [f.storeRelative(workspace: "ws", id: "sess-store")])
        XCTAssertEqual(session.absentRelativePaths, f.storeSidecars(workspace: "ws", id: "sess-store"))
        XCTAssertFalse(session.absentRelativePaths.contains { $0.hasPrefix("projects/") })

        XCTAssertEqual(try Data(contentsOf: store), beforeStore)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("state.vscdb")), beforeLegacy)
        XCTAssertEqual(Set(try f.names(in: store.deletingLastPathComponent())), ["store.db"])
    }

    func testTranscriptOnlyDoesNotFabricateStoreOrObserveMetaWithoutAStore() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeTranscript(project: "proj", id: "sess-tr")
        try f.writeFile(f.chatsSession(workspace: "other", id: "lonely-meta").appendingPathComponent("meta.json"), "SECRET-META")

        let session = try XCTUnwrap(try f.discover().first)
        XCTAssertEqual(session.nativeSessionID, "sess-tr")
        XCTAssertNil(session.storeRelativePath)
        XCTAssertEqual(session.transcriptRelativePath, f.transcriptRelative(project: "proj", id: "sess-tr"))
        XCTAssertEqual(session.present.map(\.relativePath), [f.transcriptRelative(project: "proj", id: "sess-tr")])
        XCTAssertTrue(session.absentRelativePaths.isEmpty)
        XCTAssertFalse(session.present.contains { $0.relativePath.contains("meta.json") })
        XCTAssertFalse(session.absentRelativePaths.contains { $0.contains("store.db") || $0.contains("meta.json") })
    }

    func testExactByteIDJoinsAPairAndKeepsCaseDistinctIDsSeparate() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "sess-z")
        try f.writeTranscript(project: "proj", id: "sess-z")
        try f.writeStore(workspace: "ws", id: "sess-id")
        try f.writeTranscript(project: "proj", id: "sess-ID")
        try f.writeStore(workspace: "ws", id: "sess-m")

        let sessions = try f.discover()
        XCTAssertEqual(sessions.map(\.nativeSessionID), ["sess-ID", "sess-id", "sess-m", "sess-z"])
        XCTAssertEqual(sessions[0].storeRelativePath, nil)
        XCTAssertEqual(sessions[0].transcriptRelativePath, f.transcriptRelative(project: "proj", id: "sess-ID"))
        XCTAssertEqual(sessions[1].storeRelativePath, f.storeRelative(workspace: "ws", id: "sess-id"))
        XCTAssertNil(sessions[1].transcriptRelativePath)
        XCTAssertEqual(sessions[2].storeRelativePath, f.storeRelative(workspace: "ws", id: "sess-m"))
        XCTAssertNil(sessions[2].transcriptRelativePath)
        XCTAssertEqual(sessions[3].storeRelativePath, f.storeRelative(workspace: "ws", id: "sess-z"))
        XCTAssertEqual(sessions[3].transcriptRelativePath, f.transcriptRelative(project: "proj", id: "sess-z"))
        XCTAssertTrue(sessions[3].present.map(\.relativePath).contains(f.storeRelative(workspace: "ws", id: "sess-z")))
        XCTAssertTrue(sessions[3].present.map(\.relativePath).contains(f.transcriptRelative(project: "proj", id: "sess-z")))
    }

    func testKnownOppositeDirectoryContributesOnlyTheMissingPrimary() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "has-store")
        try f.makeTranscriptSession(project: "proj", id: "has-store")
        try f.writeTranscript(project: "proj", id: "has-tr")
        try f.makeChatsSession(workspace: "ws", id: "has-tr")
        try f.writeFile(f.chatsSession(workspace: "ws", id: "has-tr").appendingPathComponent("meta.json"), "do-not-stat-without-store")

        let byID = try Dictionary(uniqueKeysWithValues: f.discover().map { ($0.nativeSessionID, $0) })
        let storeSide = try XCTUnwrap(byID["has-store"])
        XCTAssertEqual(storeSide.storeRelativePath, f.storeRelative(workspace: "ws", id: "has-store"))
        XCTAssertNil(storeSide.transcriptRelativePath)
        XCTAssertTrue(storeSide.absentRelativePaths.contains(f.transcriptRelative(project: "proj", id: "has-store")))
        XCTAssertEqual(storeSide.absentRelativePaths.filter { $0.hasPrefix("projects/") }.count, 1)

        let transcriptSide = try XCTUnwrap(byID["has-tr"])
        XCTAssertNil(transcriptSide.storeRelativePath)
        XCTAssertEqual(transcriptSide.transcriptRelativePath, f.transcriptRelative(project: "proj", id: "has-tr"))
        XCTAssertEqual(
            transcriptSide.absentRelativePaths.filter { $0.contains("store.db") },
            [f.storeRelative(workspace: "ws", id: "has-tr")]
        )
        XCTAssertFalse(transcriptSide.absentRelativePaths.contains { $0.hasSuffix("meta.json") || $0.contains("store.db-") })
        XCTAssertFalse(transcriptSide.present.contains { $0.relativePath.hasSuffix("meta.json") })
    }

    func testEmptyDirectoriesAreNotDuplicateSessionsAndUnrelatedDepthIsIgnored() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "real", id: "shared")
        try f.makeChatsSession(workspace: "empty-a", id: "shared")
        try f.makeChatsSession(workspace: "empty-b", id: "shared")
        try f.writeTranscript(project: "real", id: "tr-only")
        try f.makeTranscriptSession(project: "empty-a", id: "tr-only")
        try f.writeFile(f.chatsSession(workspace: "real", id: "shared").appendingPathComponent("notes.txt"), "noise")
        try f.writeFile(f.chatsSession(workspace: "real", id: "shared").appendingPathComponent("nested/store.db"), f.invalidStoreBytes)
        try f.writeFile(f.root.appendingPathComponent("projects/real/agent-transcripts/tr-only/other.jsonl"), "{}\n")
        try f.writeFile(f.root.appendingPathComponent("chats/real/store.db"), f.invalidStoreBytes)

        let sessions = try f.discover()
        XCTAssertEqual(sessions.map(\.nativeSessionID), ["shared", "tr-only"])
        XCTAssertEqual(sessions[0].storeRelativePath, f.storeRelative(workspace: "real", id: "shared"))
        XCTAssertFalse(sessions[0].present.contains { $0.relativePath.contains("notes.txt") || $0.relativePath.contains("nested/") })
        XCTAssertNil(sessions[1].storeRelativePath)
        XCTAssertEqual(sessions[1].present.map(\.relativePath), [f.transcriptRelative(project: "real", id: "tr-only")])
    }

    func testMultipleKnownOppositeDirectoriesRecordEveryMissingPrimary() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeTranscript(project: "proj", id: "only-tr")
        try f.makeChatsSession(workspace: "empty-a", id: "only-tr")
        try f.makeChatsSession(workspace: "empty-b", id: "only-tr")
        try f.writeStore(workspace: "ws", id: "only-store")
        try f.makeTranscriptSession(project: "empty-a", id: "only-store")
        try f.makeTranscriptSession(project: "empty-b", id: "only-store")

        let byID = try Dictionary(uniqueKeysWithValues: f.discover().map { ($0.nativeSessionID, $0) })
        let transcript = try XCTUnwrap(byID["only-tr"])
        XCTAssertNil(transcript.storeRelativePath)
        XCTAssertEqual(transcript.transcriptRelativePath, f.transcriptRelative(project: "proj", id: "only-tr"))
        XCTAssertEqual(
            Set(transcript.absentRelativePaths.filter { $0.hasSuffix("/store.db") }),
            [f.storeRelative(workspace: "empty-a", id: "only-tr"), f.storeRelative(workspace: "empty-b", id: "only-tr")]
        )
        let store = try XCTUnwrap(byID["only-store"])
        XCTAssertEqual(store.storeRelativePath, f.storeRelative(workspace: "ws", id: "only-store"))
        XCTAssertNil(store.transcriptRelativePath)
        XCTAssertEqual(
            Set(store.absentRelativePaths.filter { $0.hasPrefix("projects/") }),
            [
                f.transcriptRelative(project: "empty-a", id: "only-store"),
                f.transcriptRelative(project: "empty-b", id: "only-store"),
            ]
        )
    }

    func testDuplicatePrimaryLocatorsAreRefused() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws-a", id: "dup")
        try f.writeStore(workspace: "ws-b", id: "dup")
        assertRefused { try f.discover() }

        let g = try CursorFixture(); defer { g.remove() }
        try g.writeTranscript(project: "p-a", id: "dup")
        try g.writeTranscript(project: "p-b", id: "dup")
        assertRefused { try g.discover() }
    }

    func testDependenciesAddedAndRemovedChangeMembershipNotInventedPaths() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let store = try f.writeStore(workspace: "ws", id: "live")
        let first = try XCTUnwrap(try f.discover().first)
        XCTAssertEqual(first.absentRelativePaths, f.storeSidecars(workspace: "ws", id: "live"))

        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("store.db-wal"), "wal")
        try f.writeFile(store.deletingLastPathComponent().appendingPathComponent("meta.json"), "meta")
        let added = try XCTUnwrap(try f.discover().first)
        XCTAssertNotEqual(first, added)
        XCTAssertTrue(added.present.map(\.relativePath).contains(f.storeRelative(workspace: "ws", id: "live") + "-wal"))
        XCTAssertTrue(added.present.map(\.relativePath).contains("chats/ws/live/meta.json"))
        XCTAssertFalse(added.absentRelativePaths.contains { $0.hasSuffix("store.db-wal") || $0.hasSuffix("meta.json") })

        try FileManager.default.removeItem(at: store.deletingLastPathComponent().appendingPathComponent("meta.json"))
        try f.writeTranscript(project: "proj", id: "live")
        let paired = try XCTUnwrap(try f.discover().first)
        XCTAssertEqual(paired.transcriptRelativePath, f.transcriptRelative(project: "proj", id: "live"))
        XCTAssertTrue(paired.absentRelativePaths.contains("chats/ws/live/meta.json"))

        try FileManager.default.removeItem(at: f.root.appendingPathComponent(f.transcriptRelative(project: "proj", id: "live")))
        let removed = try XCTUnwrap(try f.discover().first)
        XCTAssertNil(removed.transcriptRelativePath)
        XCTAssertTrue(removed.absentRelativePaths.contains(f.transcriptRelative(project: "proj", id: "live")))
    }

    func testHookFencingRejectsRecognizedMutationsAndDropsUnrelatedPayload() throws {
        func seeded() throws -> (CursorFixture, URL) {
            let f = try CursorFixture()
            let store = try f.writeStore(workspace: "ws", id: "fence")
            return (f, store.deletingLastPathComponent())
        }

        let wal = try seeded(); defer { wal.0.remove() }
        assertRefused { try wal.0.discover { try wal.0.writeFile(wal.1.appendingPathComponent("store.db-wal"), "late-wal") } }

        let meta = try seeded(); defer { meta.0.remove() }
        assertRefused { try meta.0.discover { try meta.0.writeFile(meta.1.appendingPathComponent("meta.json"), "late-meta") } }

        let transcript = try seeded(); defer { transcript.0.remove() }
        assertRefused { try transcript.0.discover { try transcript.0.writeTranscript(project: "proj", id: "fence") } }

        let session = try seeded(); defer { session.0.remove() }
        assertRefused {
            try session.0.discover {
                try session.0.replaceDirectory(session.1) { try session.0.writeStore(workspace: "ws", id: "fence") }
            }
        }

        let root = try seeded(); defer { root.0.remove() }
        assertRefused {
            try root.0.discover {
                try root.0.replaceDirectory(root.0.root) { try root.0.writeStore(workspace: "ws", id: "fence") }
            }
        }

        // Unrelated scratch between observations may succeed: directory identities
        // and recognized members are unchanged; the file must not become payload.
        let unrelated = try seeded(); defer { unrelated.0.remove() }
        let observed = try unrelated.0.discover {
            try unrelated.0.writeFile(unrelated.1.appendingPathComponent("scratch.txt"), "unrelated")
        }
        let found = try XCTUnwrap(observed.first)
        XCTAssertFalse(found.present.contains { $0.relativePath.contains("scratch.txt") })
        XCTAssertFalse(found.absentRelativePaths.contains { $0.contains("scratch.txt") })
    }

    func testHookRefusesExistingWalMetaAndTranscriptByteMutation() throws {
        func seededPair() throws -> (CursorFixture, URL) {
            let f = try CursorFixture()
            let store = try f.writeStore(workspace: "ws", id: "mut")
            let dir = store.deletingLastPathComponent()
            try f.writeFile(dir.appendingPathComponent("store.db-wal"), "wal-v1")
            try f.writeFile(dir.appendingPathComponent("meta.json"), "meta-v1")
            try f.writeTranscript(project: "proj", id: "mut")
            return (f, dir)
        }

        let wal = try seededPair(); defer { wal.0.remove() }
        assertRefused { try wal.0.discover { try wal.0.writeFile(wal.1.appendingPathComponent("store.db-wal"), "wal-v2") } }

        let meta = try seededPair(); defer { meta.0.remove() }
        assertRefused { try meta.0.discover { try meta.0.writeFile(meta.1.appendingPathComponent("meta.json"), "meta-v2") } }

        let transcript = try seededPair(); defer { transcript.0.remove() }
        assertRefused {
            try transcript.0.discover {
                try transcript.0.writeFile(transcript.0.transcriptURL(project: "proj", id: "mut"), Data("{changed}\n".utf8))
            }
        }
    }

    func testBudgetCountsUnrelatedVisitedEntriesAndRejectsNonPositiveLimits() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "budget")
        for i in 0..<80 {
            try f.writeFile(f.chatsSession(workspace: "ws", id: "budget").appendingPathComponent("noise-\(i).txt"), "x")
        }
        assertRefused { try f.discover(maximumDirectoryEntries: 0) }
        assertRefused { try f.discover(maximumDirectoryEntries: -1) }
        assertRefused { try f.discover(maximumDirectoryEntries: 24) }
        XCTAssertEqual(try f.discover().map(\.nativeSessionID), ["budget"])
    }

    func testUnsafeRecognizedPathsAndNoncanonicalOrMissingRootsAreRefused() throws {
        let f = try CursorFixture(); defer { f.remove() }
        try f.writeStore(workspace: "ws", id: "safe")
        let outside = f.base.appendingPathComponent("outside.db")
        try f.writeFile(outside, f.invalidStoreBytes)

        let linked = try CursorFixture(); defer { linked.remove() }
        try linked.makeChatsSession(workspace: "ws", id: "link")
        try FileManager.default.createSymbolicLink(
            at: linked.chatsSession(workspace: "ws", id: "link").appendingPathComponent("store.db"),
            withDestinationURL: outside
        )
        assertRefused { try linked.discover() }

        let fifo = try CursorFixture(); defer { fifo.remove() }
        try fifo.makeChatsSession(workspace: "ws", id: "fifo")
        XCTAssertEqual(mkfifo(fifo.chatsSession(workspace: "ws", id: "fifo").appendingPathComponent("store.db").path, 0o600), 0)
        assertRefused { try fifo.discover() }

        let trLink = try CursorFixture(); defer { trLink.remove() }
        try trLink.makeTranscriptSession(project: "proj", id: "link")
        try FileManager.default.createSymbolicLink(
            at: trLink.transcriptURL(project: "proj", id: "link"),
            withDestinationURL: outside
        )
        assertRefused { try trLink.discover() }

        let sidecarLink = try CursorFixture(); defer { sidecarLink.remove() }
        let sidecarStore = try sidecarLink.writeStore(workspace: "ws", id: "side")
        try FileManager.default.createSymbolicLink(
            at: sidecarStore.deletingLastPathComponent().appendingPathComponent("store.db-wal"),
            withDestinationURL: outside
        )
        assertRefused { try sidecarLink.discover() }

        let sidecarFIFO = try CursorFixture(); defer { sidecarFIFO.remove() }
        let fifoStore = try sidecarFIFO.writeStore(workspace: "ws", id: "side")
        XCTAssertEqual(mkfifo(fifoStore.deletingLastPathComponent().appendingPathComponent("meta.json").path, 0o600), 0)
        assertRefused { try sidecarFIFO.discover() }

        let alias = f.base.appendingPathComponent("alias-root")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        assertRefused { try CollectorCursorSource.discoverModern(rootPath: alias.path) }

        let parentAlias = f.base.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: f.base)
        assertRefused {
            try CollectorCursorSource.discoverModern(rootPath: parentAlias.appendingPathComponent(f.root.lastPathComponent).path)
        }

        for path in [f.root.path + "/../" + f.root.lastPathComponent, f.root.path + "/.", "relative-root", f.root.path + "//"] {
            assertRefused { try CollectorCursorSource.discoverModern(rootPath: path) }
        }
        assertRefused { try CollectorCursorSource.discoverModern(rootPath: f.base.appendingPathComponent("missing").path) }
    }

    func testReadCapturedStoreMetadataReturnsWALOnlyAndMainOnlyKey0AfterOriginalRemoval() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let hex = hexUTF8(#"{"cwd":"/wal"}"#)
        let walPair = try captureStoreBytes(at: f.root.appendingPathComponent("store.db"), wal: true, sql: """
            CREATE TABLE meta(key TEXT, value TEXT);
            PRAGMA wal_checkpoint(TRUNCATE);
            BEGIN; INSERT INTO meta VALUES('0','\(hex)'); COMMIT;
            """)
        XCTAssertNil(walPair.main.range(of: Data(hex.utf8)))
        XCTAssertNotNil(try XCTUnwrap(walPair.wal).range(of: Data(hex.utf8)))
        try FileManager.default.removeItem(at: f.root)
        XCTAssertEqual(try readCaptured(f, main: walPair.main, wal: walPair.wal), hex)

        let mainOnly = try CursorFixture(); defer { mainOnly.remove() }
        let pair = try captureStoreBytes(at: mainOnly.root.appendingPathComponent("store.db"), wal: false, sql: """
            CREATE TABLE meta(key TEXT, value TEXT);
            INSERT INTO meta VALUES('0','main-only-key0');
            """)
        XCTAssertNil(pair.wal)
        try FileManager.default.removeItem(at: mainOnly.root)
        XCTAssertEqual(try readCaptured(mainOnly, main: pair.main, wal: nil), "main-only-key0")
    }

    func testReadCapturedStoreMetadataReturnsKey0ForPrimaryKeyWithoutRowidAndExplicitIndex() throws {
        let schemas: [(String, String, String)] = [
            ("pk", "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);", "pk-key0"),
            ("without-rowid", "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;", "without-rowid-key0"),
            ("explicit-index", "CREATE TABLE meta(key TEXT, value TEXT); CREATE INDEX meta_key ON meta(key);", "index-key0"),
        ]
        for (name, ddl, key0) in schemas {
            let f = try CursorFixture(); defer { f.remove() }
            let pair = try captureStoreBytes(at: f.root.appendingPathComponent("store.db"), wal: false, sql: """
                \(ddl)
                INSERT INTO meta VALUES('0','\(key0)');
                """)
            try FileManager.default.removeItem(at: f.root)
            XCTAssertEqual(try readCaptured(f, main: pair.main, wal: nil), key0, name)
        }
    }

    func testReadCapturedStoreMetadataHandlesCheckpointedWALModeWithoutRecoveryWrites() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let pair = try captureStoreBytes(at: f.root.appendingPathComponent("store.db"), wal: true, sql: """
            CREATE TABLE meta(key TEXT, value TEXT);
            INSERT INTO meta VALUES('0','checkpointed-key0');
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        XCTAssertEqual(try XCTUnwrap(pair.wal).count, 0)
        XCTAssertEqual(pair.main[18], 2)
        try FileManager.default.removeItem(at: f.root)
        XCTAssertEqual(try readCaptured(f, main: pair.main, wal: nil), "checkpointed-key0")
        XCTAssertEqual(try readCaptured(f, main: pair.main, wal: Data()), "checkpointed-key0")
    }

    func testReadCapturedStoreMetadataReturnsNilForMissingOrNullKey0() throws {
        for sql in [
            "CREATE TABLE meta(key TEXT, value TEXT);",
            "CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('0', NULL);",
            "CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('other','x');",
        ] {
            let f = try CursorFixture(); defer { f.remove() }
            let pair = try captureStoreBytes(at: f.root.appendingPathComponent("store.db"), wal: false, sql: sql)
            try FileManager.default.removeItem(at: f.root)
            XCTAssertNil(try readCaptured(f, main: pair.main, wal: nil), sql)
        }
    }

    func testReadCapturedStoreMetadataRefusesViewVirtualDuplicateAndMalformedKey0() throws {
        let cases: [(String, String)] = [
            ("view", """
                CREATE TABLE payload(key TEXT, value TEXT);
                INSERT INTO payload VALUES('0','view-cwd');
                CREATE VIEW meta AS SELECT key, value FROM payload;
                """),
            ("virtual", """
                CREATE VIRTUAL TABLE meta USING fts5(key, value);
                INSERT INTO meta VALUES('0','virtual-cwd');
                """),
            ("duplicate", """
                CREATE TABLE meta(key TEXT, value TEXT);
                INSERT INTO meta VALUES('0','first'); INSERT INTO meta VALUES('0','second');
                """),
            ("nul", """
                CREATE TABLE meta(key TEXT, value TEXT);
                INSERT INTO meta VALUES('0', char(97, 0, 98));
                """),
            ("utf8", """
                CREATE TABLE meta(key TEXT, value TEXT);
                INSERT INTO meta VALUES('0', CAST(x'80' AS TEXT));
                """),
        ]
        for (name, sql) in cases {
            let f = try CursorFixture(); defer { f.remove() }
            let pair = try captureStoreBytes(at: f.root.appendingPathComponent("store.db"), wal: false, sql: sql)
            try FileManager.default.removeItem(at: f.root)
            XCTAssertThrowsError(try readCaptured(f, main: pair.main, wal: nil), name) {
                XCTAssertEqual($0 as? CollectorSQLiteSnapshotError, .unsafePath, name)
            }
        }
        let garbage = try CursorFixture(); defer { garbage.remove() }
        try FileManager.default.removeItem(at: garbage.root)
        XCTAssertThrowsError(try readCaptured(garbage, main: Data("not-a-sqlite-database".utf8), wal: nil)) {
            XCTAssertTrue($0 as? CollectorSQLiteSnapshotError == .unavailable
                || $0 as? CollectorSQLiteSnapshotError == .unsafePath)
        }
    }

    func testReadCapturedStoreMetadataEnforcesByteStepDeadlineAndMetadataCaps() throws {
        let f = try CursorFixture(); defer { f.remove() }
        let pair = try captureStoreBytes(at: f.root.appendingPathComponent("store.db"), wal: false, sql: """
            CREATE TABLE meta(key TEXT, value TEXT);
            INSERT INTO meta VALUES('0','0123456789abcdef');
            """)
        try FileManager.default.removeItem(at: f.root)
        let total = Int64(pair.main.count)
        for budget in [
            CollectorCursorSource.MetadataBudget(maximumSourceBytes: 0),
            CollectorCursorSource.MetadataBudget(maximumSourceBytes: max(total - 1, 0)),
            CollectorCursorSource.MetadataBudget(maximumMetadataBytes: 3),
            CollectorCursorSource.MetadataBudget(maximumSQLiteSteps: 0),
            CollectorCursorSource.MetadataBudget(maximumSQLiteSteps: 1),
            CollectorCursorSource.MetadataBudget(maximumLeaseMilliseconds: 0),
        ] {
            XCTAssertThrowsError(try readCaptured(f, main: pair.main, wal: nil, budget: budget)) {
                XCTAssertEqual($0 as? CollectorSQLiteSnapshotError, .exceededBudget)
            }
        }
    }

    func testReadCapturedStoreMetadataCancellationAndPrivateStagingFenceCleanup() async throws {
        let f = try CursorFixture(); defer { f.remove() }
        let pair = try captureStoreBytes(at: f.root.appendingPathComponent("store.db"), wal: true, sql: """
            CREATE TABLE meta(key TEXT, value TEXT);
            PRAGMA wal_checkpoint(TRUNCATE);
            BEGIN; INSERT INTO meta VALUES('0','fence-cwd'); COMMIT;
            """)
        try FileManager.default.removeItem(at: f.root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try readCaptured(f, main: pair.main, wal: pair.wal)
        }
        do { _ = try await task.value; XCTFail("cancelled metadata read returned key0") }
        catch { XCTAssertTrue(error is CancellationError) }

        let duringQuery = Task {
            try readCaptured(f, main: pair.main, wal: pair.wal, hooks: .init(beforeMetadataQuery: {
                withUnsafeCurrentTask { $0?.cancel() }
            }))
        }
        do { _ = try await duringQuery.value; XCTFail("query-phase cancellation returned metadata") }
        catch { XCTAssertTrue(error is CancellationError) }

        for change in ["main", "wal-link", "query"] {
            let staging = f.base.appendingPathComponent("meta-fence-\(change)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let hooks = CollectorCursorSource.CapturedStoreTestHooks(
                beforeSQLiteOpen: { privateURL in
                    XCTAssertTrue(privateURL.path.hasPrefix(staging.path))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
                    switch change {
                    case "main":
                        try Data("tampered-private-main".utf8).write(to: privateURL)
                    case "wal-link":
                        let wal = URL(fileURLWithPath: privateURL.path + "-wal")
                        try? FileManager.default.removeItem(at: wal)
                        try FileManager.default.createSymbolicLink(at: wal, withDestinationURL: f.base)
                    default: break
                    }
                },
                beforeMetadataQuery: {
                    if change == "query" { throw CollectorSQLiteSnapshotError.sourceChanged }
                }
            )
            XCTAssertThrowsError(try CollectorCursorSource.readCapturedStoreMetadata(
                databaseBytes: pair.main, walBytes: pair.wal, stagingParent: staging, testHooks: hooks
            ), change) {
                if change == "query" {
                    XCTAssertEqual($0 as? CollectorSQLiteSnapshotError, .sourceChanged)
                } else {
                    XCTAssertTrue($0 as? CollectorSQLiteSnapshotError == .sourceChanged
                        || $0 as? CollectorSQLiteSnapshotError == .unsafePath, change)
                }
            }
            XCTAssertEqual(try f.names(in: staging), [])
        }
    }

    func testEmptyAndMissingTreesAreValidWhenTheRootExists() throws {
        let empty = try CursorFixture(); defer { empty.remove() }
        XCTAssertEqual(try empty.discover(), [])

        let chatsOnly = try CursorFixture(); defer { chatsOnly.remove() }
        try FileManager.default.createDirectory(at: chatsOnly.root.appendingPathComponent("chats"), withIntermediateDirectories: true)
        XCTAssertEqual(try chatsOnly.discover(), [])

        let projectsOnly = try CursorFixture(); defer { projectsOnly.remove() }
        try FileManager.default.createDirectory(at: projectsOnly.root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        XCTAssertEqual(try projectsOnly.discover(), [])

        let store = try CursorFixture(); defer { store.remove() }
        try store.writeStore(workspace: "ws", id: "only")
        XCTAssertEqual(try store.discover().map(\.nativeSessionID), ["only"])

        let transcript = try CursorFixture(); defer { transcript.remove() }
        try transcript.writeTranscript(project: "proj", id: "only")
        XCTAssertEqual(try transcript.discover().map(\.nativeSessionID), ["only"])
    }
}

private struct CursorFixture {
    let invalidStoreBytes = Data("not-a-sqlite-database".utf8)
    let base: URL
    let root: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("engram-cursor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        root = base.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func discover(
        maximumDirectoryEntries: Int = 4096,
        _ hook: (() throws -> Void)? = nil
    ) throws -> [CollectorCursorSource.ModernSession] {
        try CollectorCursorSource.discoverModern(
            rootPath: root.path,
            maximumDirectoryEntries: maximumDirectoryEntries,
            beforeFinalValidation: hook
        )
    }

    func capture(
        _ session: CollectorCursorSource.ModernSession, maximumByteCount: Int64 = 16 * 1024 * 1024,
        maximumDirectoryEntries: Int = 4096, budget: CollectorSQLiteSnapshotLease.Budget = .init(),
        testHooks: CollectorCursorSource.CaptureTestHooks = .init()
    ) throws -> CollectorCursorSource.ModernCapture {
        let staging = base.appendingPathComponent("capture-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { XCTAssertTrue((try? names(in: staging).isEmpty) == true) }
        return try CollectorCursorSource.captureModern(rootPath: root.path, session: session, stagingParent: staging,
            maximumByteCount: maximumByteCount, maximumDirectoryEntries: maximumDirectoryEntries,
            budget: budget, testHooks: testHooks)
    }

    func storeRelative(workspace: String, id: String) -> String {
        "chats/\(workspace)/\(id)/store.db"
    }

    func transcriptRelative(project: String, id: String) -> String {
        "projects/\(project)/agent-transcripts/\(id)/\(id).jsonl"
    }

    func storeSidecars(workspace: String, id: String) -> [String] {
        ["store.db-journal", "store.db-shm", "store.db-wal", "meta.json"].map { "chats/\(workspace)/\(id)/\($0)" }.sorted()
    }

    func chatsSession(workspace: String, id: String) -> URL {
        root.appendingPathComponent("chats/\(workspace)/\(id)", isDirectory: true)
    }

    func transcriptURL(project: String, id: String) -> URL {
        root.appendingPathComponent(transcriptRelative(project: project, id: id))
    }

    @discardableResult
    func writeStore(workspace: String, id: String) throws -> URL {
        let url = chatsSession(workspace: workspace, id: id).appendingPathComponent("store.db")
        try writeFile(url, invalidStoreBytes)
        return url
    }

    @discardableResult
    func writeTranscript(project: String, id: String) throws -> URL {
        let url = transcriptURL(project: project, id: id)
        try writeFile(url, Data("{}\n".utf8))
        return url
    }

    func makeChatsSession(workspace: String, id: String) throws {
        try FileManager.default.createDirectory(at: chatsSession(workspace: workspace, id: id), withIntermediateDirectories: true)
    }

    func makeTranscriptSession(project: String, id: String) throws {
        try FileManager.default.createDirectory(at: transcriptURL(project: project, id: id).deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func writeFile(_ url: URL, _ body: String) throws {
        try writeFile(url, Data(body.utf8))
    }

    func writeFile(_ url: URL, _ body: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url)
    }

    func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func replaceDirectory(_ directory: URL, recreate: () throws -> Void) throws {
        let moved = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".replaced")
        try FileManager.default.moveItem(at: directory, to: moved)
        try recreate()
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private func fstatatFolds(parent: URL, requested: String) -> Bool {
    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { _ = Darwin.close(fd) }
    var info = stat()
    return requested.withCString { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) } == 0
}

private func assertRefused<T>(
    _ work: () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
        if let posix = error as? CollectorPOSIXEnumerationError {
            XCTAssertNotEqual(posix, .notImplemented, "refusal must be behavioral, not the draft stub", file: file, line: line)
        }
    }
}

private func hexUTF8(_ text: String) -> String {
    Data(text.utf8).map { String(format: "%02x", $0) }.joined()
}

/// Capture main/WAL while the writer is still open, then close. Caller deletes the original tree before SQL.
private func captureStoreBytes(at url: URL, wal: Bool, sql: String) throws -> (main: Data, wal: Data?) {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else { throw POSIXError(.EIO) }
    defer { sqlite3_close(db) }
    let preamble = wal
        ? "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;"
        : "PRAGMA journal_mode=DELETE;"
    guard sqlite3_exec(db, preamble + sql, nil, nil, nil) == SQLITE_OK else {
        throw POSIXError(.EIO)
    }
    if wal { guard sqlite3_db_cacheflush(db) == SQLITE_OK else { throw POSIXError(.EIO) } }
    let main = try Data(contentsOf: url)
    let walURL = URL(fileURLWithPath: url.path + "-wal")
    let walBytes = wal && FileManager.default.fileExists(atPath: walURL.path) ? try Data(contentsOf: walURL) : nil
    return (main, walBytes)
}

private func readCaptured(
    _ f: CursorFixture, main: Data, wal: Data?,
    budget: CollectorCursorSource.MetadataBudget = .init(),
    hooks: CollectorCursorSource.CapturedStoreTestHooks = .init()
) throws -> String? {
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path), "original tree must be gone before private SQL")
    let staging = f.base.appendingPathComponent("meta-staging-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { XCTAssertEqual((try? f.names(in: staging)) ?? ["missing"], []) }
    return try CollectorCursorSource.readCapturedStoreMetadata(
        databaseBytes: main, walBytes: wal, stagingParent: staging, budget: budget, testHooks: hooks)
}

import Darwin
import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class ArchiveCursorLegacyCaptureTests: XCTestCase {
    private let machineID = "11111111-2222-3333-4444-555555555555"
    private let captureDigest = String(repeating: "a", count: 64)
    private let sourceDigest = String(repeating: "b", count: 64)
    private let chunkDigest = String(repeating: "c", count: 64)
    private var root: URL!

    func testContextMirrorsSessionWithoutEncodingNativeCountOnTheBody() throws {
        let session = try makeSession()
        let fromSession = try ArchiveCursorLegacyContext(session: session)
        let fromFields = try ArchiveCursorLegacyContext(
            databaseLocator: session.logicalDatabaseLocator,
            composerID: session.composerID,
            cwd: session.cwd,
            rawPayloadByteCount: session.rawPayloadByteCount,
            nativePayloadByteCount: session.nativePayloadByteCount,
            walGeneration: session.walGeneration
        )
        XCTAssertEqual(fromSession, fromFields)
        XCTAssertEqual(fromSession.kind, "cursorLegacyRowsV1")
        XCTAssertEqual(fromSession.logicalLocator, session.logicalLocator)
        XCTAssertEqual(
            fromSession.logicalLocator,
            session.logicalDatabaseLocator + "?composer=" + session.composerID
        )
        XCTAssertEqual(fromSession.rawPayloadByteCount, session.rawPayloadByteCount)
        XCTAssertEqual(fromSession.nativePayloadByteCount, session.nativePayloadByteCount)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session.encodeCanonical()) as? [String: Any]
        )
        XCTAssertNil(body["nativePayloadByteCount"])
        XCTAssertEqual(body["kind"] as? String, "cursorLegacyRowsV1")
        let encodedContext = try ArchiveCanonicalJSON.encode(fromSession)
        let contextJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedContext) as? [String: Any])
        XCTAssertEqual(contextJSON["kind"] as? String, "cursorLegacyRowsV1")
        XCTAssertEqual(contextJSON["nativePayloadByteCount"] as? Int, Int(session.nativePayloadByteCount))
        XCTAssertEqual(try ArchiveCanonicalJSON.decode(ArchiveCursorLegacyContext.self, from: encodedContext), fromSession)
    }

    func testByteIdentityDistinguishesNFCNFDAndLiteralSpecialComposerIDs() throws {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        let nfcSession = try makeSession(id: nfc)
        let nfdSession = try makeSession(id: nfd)
        XCTAssertNotEqual(nfcSession, nfdSession)
        XCTAssertNotEqual(
            try ArchiveCursorLegacyContext(session: nfcSession),
            try ArchiveCursorLegacyContext(session: nfdSession)
        )
        XCTAssertTrue(nfcSession.logicalLocator.utf8.elementsEqual(
            (nfcSession.logicalDatabaseLocator + "?composer=" + nfc).utf8
        ))

        for special in ["a:b", "id%like", "id_like", "q?x"] {
            let session = try makeSession(id: special)
            let context = try ArchiveCursorLegacyContext(session: session)
            XCTAssertEqual(context.composerID.utf8.map { $0 }, Array(special.utf8))
            XCTAssertEqual(context.logicalLocator, session.logicalLocator)
            XCTAssertEqual(try ArchiveCursorLegacyContext(session: session), context)
        }

        let generation = try dbGeneration()
        let digest = ArchiveV2Hash.sha256(Data("same-body".utf8))
        XCTAssertNotEqual(
            try ExactSourceCapturer.cursorLegacySessionCaptureID(
                machineID: machineID,
                context: ArchiveCursorLegacyContext(session: nfcSession),
                generation: generation,
                wholeSourceSHA256: digest
            ),
            try ExactSourceCapturer.cursorLegacySessionCaptureID(
                machineID: machineID,
                context: ArchiveCursorLegacyContext(session: nfdSession),
                generation: generation,
                wholeSourceSHA256: digest
            )
        )
    }

    func testNativePayloadByteCountMatchesPhase4InMemoryQuery() throws {
        let composer = #"{"composerId":"owned"}"#
        let visible = #"{"type":1,"text":"keep"}"#
        let blobHello = Data(#"{"type":2,"text":"hello"}"#.utf8)
        let nul = Data("pre".utf8) + Data([0]) + Data("post".utf8)
        let invalid = Data([0x61, 0xFF, 0xFE, 0x80])
        let session = try ArchiveCursorLegacySession(
            logicalDatabaseLocator: "/tmp/engram-cursor-legacy-replay/state.vscdb",
            composerID: "owned",
            cwd: "",
            databaseGeneration: try dbGeneration(),
            walGeneration: nil,
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:owned", value: Data(composer.utf8)
            ),
            bubbles: [
                ArchiveCursorLegacySession.Row(rowID: 2, key: "bubbleId:owned:keep", value: Data(visible.utf8)),
                ArchiveCursorLegacySession.Row(
                    rowID: 3, key: "bubbleId:owned:hello", value: blobHello, storage: .blob
                ),
                ArchiveCursorLegacySession.Row(
                    rowID: 4, key: "bubbleId:owned:nul", value: nul, storage: .blob
                ),
                ArchiveCursorLegacySession.Row(
                    rowID: 5, key: "bubbleId:owned:invalid", value: invalid, storage: .blob
                ),
                ArchiveCursorLegacySession.Row(rowID: 6, key: "bubbleId:owned:empty", value: nil, storage: .null),
            ]
        )
        let native = try phase4NativeByteCount(session)
        XCTAssertEqual(session.nativePayloadByteCount, native)
        XCTAssertEqual(try ArchiveCursorLegacyContext(session: session).nativePayloadByteCount, native)
        XCTAssertEqual(
            session.rawPayloadByteCount,
            Int64(composer.utf8.count + visible.utf8.count + blobHello.count + nul.count + invalid.count)
        )
        XCTAssertEqual(session.nativePayloadByteCount, session.rawPayloadByteCount + 1)
        XCTAssertGreaterThan(session.nativePayloadByteCount, session.rawPayloadByteCount)
        XCTAssertLessThanOrEqual(session.nativePayloadByteCount, 3 * session.rawPayloadByteCount)
    }

    func testContextRejectsInvalidPathIdentityCwdCountsAndNonregularWAL() throws {
        let wal = try dbGeneration(size: 8)
        XCTAssertNoThrow(try provenanceContext(raw: 1, native: 0))
        XCTAssertNoThrow(try provenanceContext(raw: 16 * 1024 * 1024, native: 48 * 1024 * 1024, wal: wal))
        XCTAssertThrowsError(try ArchiveCursorLegacyContext(
            databaseLocator: "tmp/state.vscdb", composerID: "owned", cwd: "",
            rawPayloadByteCount: 2, nativePayloadByteCount: 2, walGeneration: nil
        ))
        XCTAssertThrowsError(try ArchiveCursorLegacyContext(
            databaseLocator: "/tmp/state.vscdb?composer=owned", composerID: "owned", cwd: "",
            rawPayloadByteCount: 2, nativePayloadByteCount: 2, walGeneration: nil
        ))
        XCTAssertThrowsError(try ArchiveCursorLegacyContext(
            databaseLocator: "/tmp/state.vscdb.bak", composerID: "owned", cwd: "",
            rawPayloadByteCount: 2, nativePayloadByteCount: 2, walGeneration: nil
        ))
        XCTAssertThrowsError(try provenanceContext(id: ""))
        XCTAssertThrowsError(try provenanceContext(id: "id\0tail"))
        XCTAssertThrowsError(try provenanceContext(cwd: "/"))
        XCTAssertThrowsError(try provenanceContext(cwd: "relative/project"))
        XCTAssertThrowsError(try provenanceContext(cwd: "/tmp/project/../escape"))
        XCTAssertThrowsError(try provenanceContext(raw: 0, native: 0))
        XCTAssertThrowsError(try provenanceContext(raw: 16 * 1024 * 1024 + 1, native: 0))
        XCTAssertThrowsError(try provenanceContext(raw: 2, native: -1))
        XCTAssertThrowsError(try provenanceContext(raw: 2, native: 7))
        XCTAssertThrowsError(try provenanceContext(wal: try dbGeneration(mode: 0o040755)))
    }

    func testReplayLayoutAcceptsLegacyContextAndRejectsMixes() throws {
        let context = try provenanceContext()
        let layout = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["session.cursor-legacy.json"],
            cursorLegacySession: context
        )
        XCTAssertEqual(layout.relativePaths, ["session.cursor-legacy.json"])
        XCTAssertEqual(layout.cursorLegacySession, context)
        XCTAssertNil(layout.sqliteSession)

        let sqlite = try ArchiveSQLiteSessionContext(
            databaseLocator: "/offline/opencode.db",
            nativeSessionID: "ses-one",
            nativePayloadByteCount: 2,
            walGeneration: nil
        )
        XCTAssertNoThrow(try ArchiveReplayLayout(
            strategy: .singleFile, relativePaths: ["session.sqlite"], sqliteSession: sqlite
        ))
        XCTAssertThrowsError(try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["other.json"],
            cursorLegacySession: context
        ))
        XCTAssertThrowsError(try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["session.cursor-legacy.json"],
            sqliteSession: sqlite,
            cursorLegacySession: context
        ))

        let fileSet = try fileSetManifest()
        let encoded = try ArchiveCanonicalJSON.encode(fileSet)
        XCTAssertEqual(try mutatingCanonical(encoded) { _ in }, encoded)
        let explicitNull = try mutatingCanonical(encoded) { object in
            var layout = object["replayLayout"] as! [String: Any]
            layout["cursorLegacySession"] = NSNull()
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: explicitNull))
        let mixed = try mutatingCanonical(encoded) { object in
            var layout = object["replayLayout"] as! [String: Any]
            layout["cursorLegacySession"] = try contextObject()
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: mixed))
    }

    func testSchemaSixRequiresLegacyContextAndOlderCanonicalBytesStayCompatible() throws {
        let manifest = try schemaSixManifest()
        XCTAssertEqual(manifest.schemaVersion, 6)
        XCTAssertEqual(manifest.source, "cursor")
        XCTAssertNil(manifest.sessionID)
        XCTAssertEqual(manifest.locator, try provenanceContext().logicalLocator)
        XCTAssertEqual(manifest.generation.size, 8_192)
        XCTAssertNotEqual(manifest.generation.size, manifest.rawByteCount)
        XCTAssertGreaterThan(manifest.rawByteCount, 0)
        XCTAssertLessThanOrEqual(manifest.rawByteCount, 128 * 1024 * 1024)
        let context = try XCTUnwrap(manifest.replayLayout.cursorLegacySession)
        XCTAssertLessThanOrEqual(context.rawPayloadByteCount, manifest.rawByteCount)
        XCTAssertGreaterThan(context.nativePayloadByteCount, manifest.rawByteCount)
        XCTAssertLessThanOrEqual(context.nativePayloadByteCount, 3 * context.rawPayloadByteCount)
        XCTAssertTrue(ArchiveSourceDescriptor.isCursorLegacySession(manifest))
        XCTAssertFalse(ArchiveSourceDescriptor.isOpenCodeSessionImage(manifest))

        let encoded = try ArchiveCanonicalJSON.encode(manifest)
        XCTAssertEqual(try mutatingCanonical(encoded) { _ in }, encoded)
        XCTAssertEqual(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: encoded), manifest)

        let schema1 = try schemaOneManifest()
        let schema1Bytes = try ArchiveCanonicalJSON.encode(schema1)
        XCTAssertEqual(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: schema1Bytes), schema1)
        XCTAssertFalse(ArchiveSourceDescriptor.isCursorLegacySession(schema1))
        let schema4 = try openCodeManifest()
        let schema4Bytes = try ArchiveCanonicalJSON.encode(schema4)
        XCTAssertEqual(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: schema4Bytes), schema4)
        XCTAssertFalse(ArchiveSourceDescriptor.isCursorLegacySession(schema4))

        for version in 1...5 {
            let polluted = try mutatingCanonical(encoded) { $0["schemaVersion"] = version }
            XCTAssertThrowsError(
                try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: polluted),
                "schema \(version) cannot carry cursor legacy context"
            )
        }
        for bytes in [schema1Bytes, schema4Bytes] {
            let injected = try mutatingCanonical(bytes) { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout["cursorLegacySession"] = try contextObject()
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: injected))
        }

        let missing = try mutatingCanonical(encoded) { object in
            var layout = object["replayLayout"] as! [String: Any]
            layout.removeValue(forKey: "cursorLegacySession")
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: missing))
        for (key, value) in [
            ("source", "opencode" as Any),
            ("sessionID", "bound"),
            ("locator", "/tmp/engram-cursor-legacy-replay/state.vscdb?composer=other"),
        ] {
            let mutated = try mutatingCanonical(encoded) { $0[key] = value }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: mutated), key)
        }
        let directory = try mutatingCanonical(encoded) { object in
            var generation = object["generation"] as! [String: Any]
            generation["mode"] = 0o040755
            object["generation"] = generation
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: directory))
        let emptyRaw = try mutatingCanonical(encoded) { $0["rawByteCount"] = 0 }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: emptyRaw))
        let overEncoded = try mutatingCanonical(encoded) { $0["rawByteCount"] = 128 * 1024 * 1024 + 1 }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: overEncoded))
        let reboundRaw = try mutatingCanonical(encoded) { object in
            var layout = object["replayLayout"] as! [String: Any]
            var context = layout["cursorLegacySession"] as! [String: Any]
            context["rawPayloadByteCount"] = (object["rawByteCount"] as? Int ?? 0) + 1
            layout["cursorLegacySession"] = context
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: reboundRaw))
        let wrongKind = try mutatingCanonical(encoded) { object in
            var layout = object["replayLayout"] as! [String: Any]
            var context = layout["cursorLegacySession"] as! [String: Any]
            context["kind"] = "opencodeSessionImage"
            layout["cursorLegacySession"] = context
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: wrongKind))
    }

    func testCapturePersistsCanonicalBodyAcrossCASReopenAndIdempotence() throws {
        let session = try makeSession(cwd: "/tmp/frozen-project")
        let encoded = try session.encodeCanonical()
        let (cas, catalog) = try makeStore(root.appendingPathComponent("legacy-cas"))
        defer { try? catalog.close() }
        let result = try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: machineID, cas: cas, catalog: catalog
        )
        XCTAssertEqual(result.manifest.schemaVersion, 6)
        XCTAssertEqual(result.manifest.source, "cursor")
        XCTAssertNil(result.manifest.sessionID)
        XCTAssertEqual(result.manifest.locator, session.logicalLocator)
        XCTAssertEqual(result.manifest.generation, session.databaseGeneration)
        XCTAssertEqual(result.manifest.generation.size, session.databaseGeneration.size)
        XCTAssertNotEqual(result.manifest.generation.size, result.manifest.rawByteCount)
        XCTAssertEqual(result.manifest.rawByteCount, Int64(encoded.count))
        XCTAssertEqual(result.manifest.replayLayout.relativePaths, ["session.cursor-legacy.json"])
        XCTAssertEqual(result.manifest.replayLayout.cursorLegacySession, try ArchiveCursorLegacyContext(session: session))
        XCTAssertTrue(ArchiveSourceDescriptor.isCursorLegacySession(result.manifest))
        let restored = try reconstruct(result.manifest, from: cas)
        XCTAssertEqual(restored, encoded)
        XCTAssertEqual(try ArchiveCursorLegacySession.decodeCanonical(restored), session)
        XCTAssertEqual(try catalog.capture(captureID: result.manifest.captureID), result.capture)

        let repeated = try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: machineID, cas: cas, catalog: catalog
        )
        XCTAssertEqual(repeated, result)

        try catalog.close()
        let reopened = try ArchiveCatalog(root: root.appendingPathComponent("legacy-cas"), machineID: machineID)
        try reopened.migrate()
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.capture(captureID: result.manifest.captureID), result.capture)
        XCTAssertEqual(
            try ExactSourceCapturer.captureCursorLegacySession(
                session, machineID: machineID, cas: cas, catalog: reopened
            ),
            result
        )
    }

    func testInvalidUTF8BodyCanExceedEncodedBytesAndStillCapture() throws {
        let composer = #"{"composerId":"owned"}"#
        let visible = #"{"type":1,"text":"keep"}"#
        let invalid = Data(repeating: 0xFF, count: 2_048)
        let session = try ArchiveCursorLegacySession(
            logicalDatabaseLocator: "/tmp/engram-cursor-legacy-replay/state.vscdb",
            composerID: "owned",
            cwd: "",
            databaseGeneration: try dbGeneration(),
            walGeneration: nil,
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:owned", value: Data(composer.utf8)
            ),
            bubbles: [
                ArchiveCursorLegacySession.Row(rowID: 2, key: "bubbleId:owned:keep", value: Data(visible.utf8)),
                ArchiveCursorLegacySession.Row(
                    rowID: 3, key: "bubbleId:owned:invalid", value: invalid, storage: .blob
                ),
            ]
        )
        let encoded = try session.encodeCanonical()
        XCTAssertEqual(session.nativePayloadByteCount, try phase4NativeByteCount(session))
        XCTAssertGreaterThan(session.nativePayloadByteCount, Int64(encoded.count))
        XCTAssertLessThanOrEqual(session.rawPayloadByteCount, Int64(encoded.count))
        XCTAssertLessThanOrEqual(session.nativePayloadByteCount, 3 * session.rawPayloadByteCount)

        let context = try ArchiveCursorLegacyContext(session: session)
        let layout = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["session.cursor-legacy.json"],
            cursorLegacySession: context
        )
        let digest = ArchiveV2Hash.sha256(encoded)
        let accepted = try ArchiveSourceManifest(
            schemaVersion: 6,
            captureID: captureDigest,
            machineID: machineID,
            source: "cursor",
            locator: context.logicalLocator,
            sessionID: nil,
            capturedAt: "2026-09-09T00:00:00.000Z",
            generation: session.databaseGeneration,
            wholeSourceSHA256: digest,
            rawByteCount: Int64(encoded.count),
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: digest, rawByteCount: Int64(encoded.count))],
            replayLayout: layout
        )
        let acceptedContext = try XCTUnwrap(accepted.replayLayout.cursorLegacySession)
        XCTAssertGreaterThan(acceptedContext.nativePayloadByteCount, accepted.rawByteCount)
        XCTAssertLessThanOrEqual(acceptedContext.rawPayloadByteCount, accepted.rawByteCount)

        let (cas, catalog) = try makeStore(root.appendingPathComponent("legacy-invalid-utf8"))
        defer { try? catalog.close() }
        let captured = try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: machineID, cas: cas, catalog: catalog
        )
        XCTAssertEqual(captured.manifest.rawByteCount, Int64(encoded.count))
        XCTAssertGreaterThan(
            try XCTUnwrap(captured.manifest.replayLayout.cursorLegacySession).nativePayloadByteCount,
            captured.manifest.rawByteCount
        )
        XCTAssertEqual(try reconstruct(captured.manifest, from: cas), encoded)
        XCTAssertEqual(try ArchiveCursorLegacySession.decodeCanonical(encoded).nativePayloadByteCount, session.nativePayloadByteCount)
    }

    func testEncodedBudgetExactBoundaryLeavesNoRecordOnNMinusOneOrNegative() throws {
        let session = try makeSession()
        let encoded = try session.encodeCanonical()
        let archive = root.appendingPathComponent("legacy-budget")
        let (cas, catalog) = try makeStore(archive)
        defer { try? catalog.close() }
        XCTAssertThrowsError(try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: machineID, cas: cas, catalog: catalog, maximumByteCount: -1
        )) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .invalidMaximumByteCount)
        }
        XCTAssertThrowsError(try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: machineID, cas: cas, catalog: catalog, maximumByteCount: Int64(encoded.count) - 1
        )) {
            XCTAssertEqual($0 as? ExactSourceCapturerError, .exceededMaximumByteCount(Int64(encoded.count) - 1))
        }
        XCTAssertThrowsError(try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", cas: cas, catalog: catalog
        )) {
            XCTAssertEqual(
                $0 as? ExactSourceCapturerError,
                .machineIDMismatch(expected: self.machineID, actual: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
            )
        }
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 0)
        let exact = try ExactSourceCapturer.captureCursorLegacySession(
            session, machineID: machineID, cas: cas, catalog: catalog, maximumByteCount: Int64(encoded.count)
        )
        XCTAssertEqual(exact.manifest.rawByteCount, Int64(encoded.count))
        XCTAssertEqual(try catalog.unboundCaptures(limit: 10).count, 1)
    }

    func testCaptureIdentityChangesWithContextBodyGenerationAndDomain() throws {
        let session = try makeSession()
        let otherBody = try makeSession(bubbles: [
            ArchiveCursorLegacySession.Row(
                rowID: 2, key: "bubbleId:owned:1", value: Data(#"{"type":1,"text":"other"}"#.utf8)
            ),
        ])
        let cwd = try makeSession(cwd: "/tmp/other-project")
        let wal = try ArchiveSourceGeneration(
            device: 1, inode: 3, size: 8, mtimeNs: 9, ctimeNs: 10, mode: 33_188
        )
        let withWAL = try ArchiveCursorLegacySession(
            logicalDatabaseLocator: session.logicalDatabaseLocator,
            composerID: session.composerID,
            cwd: session.cwd,
            databaseGeneration: session.databaseGeneration,
            walGeneration: wal,
            composer: session.composer,
            bubbles: session.bubbles
        )
        let laterGen = try ArchiveSourceGeneration(
            device: 1, inode: 2, size: 64, mtimeNs: 50, ctimeNs: 6, mode: 33_188
        )
        let digest = ArchiveV2Hash.sha256(try session.encodeCanonical())
        let otherDigest = ArchiveV2Hash.sha256(try otherBody.encodeCanonical())
        var ids = Set<String>()
        ids.insert(try ExactSourceCapturer.cursorLegacySessionCaptureID(
            machineID: machineID,
            context: ArchiveCursorLegacyContext(session: session),
            generation: session.databaseGeneration,
            wholeSourceSHA256: digest
        ))
        ids.insert(try ExactSourceCapturer.cursorLegacySessionCaptureID(
            machineID: machineID,
            context: ArchiveCursorLegacyContext(session: cwd),
            generation: session.databaseGeneration,
            wholeSourceSHA256: digest
        ))
        ids.insert(try ExactSourceCapturer.cursorLegacySessionCaptureID(
            machineID: machineID,
            context: ArchiveCursorLegacyContext(session: withWAL),
            generation: session.databaseGeneration,
            wholeSourceSHA256: digest
        ))
        ids.insert(try ExactSourceCapturer.cursorLegacySessionCaptureID(
            machineID: machineID,
            context: ArchiveCursorLegacyContext(session: session),
            generation: laterGen,
            wholeSourceSHA256: digest
        ))
        ids.insert(try ExactSourceCapturer.cursorLegacySessionCaptureID(
            machineID: machineID,
            context: ArchiveCursorLegacyContext(session: session),
            generation: session.databaseGeneration,
            wholeSourceSHA256: otherDigest
        ))
        XCTAssertEqual(ids.count, 5)

        let sqlite = try ArchiveSQLiteSessionContext(
            databaseLocator: "/offline/opencode.db",
            nativeSessionID: "owned",
            nativePayloadByteCount: 2,
            walGeneration: nil
        )
        XCTAssertNotEqual(
            try ExactSourceCapturer.cursorLegacySessionCaptureID(
                machineID: machineID,
                context: ArchiveCursorLegacyContext(session: session),
                generation: session.databaseGeneration,
                wholeSourceSHA256: digest
            ),
            try ExactSourceCapturer.sqliteSessionImageCaptureID(
                machineID: machineID,
                context: sqlite,
                generation: session.databaseGeneration,
                wholeSourceSHA256: digest
            )
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cursor-legacy-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical))
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeSession(
        locator: String = "/tmp/engram-cursor-legacy-replay/state.vscdb",
        id: String = "owned",
        cwd: String = "",
        bubbles: [ArchiveCursorLegacySession.Row] = []
    ) throws -> ArchiveCursorLegacySession {
        try ArchiveCursorLegacySession(
            logicalDatabaseLocator: locator,
            composerID: id,
            cwd: cwd,
            databaseGeneration: try dbGeneration(),
            walGeneration: nil,
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:\(id)", value: Data(#"{"composerId":"\#(id)"}"#.utf8)
            ),
            bubbles: bubbles
        )
    }

    private func dbGeneration(size: Int64 = 64, mode: Int64 = 33_188) throws -> ArchiveSourceGeneration {
        try ArchiveSourceGeneration(device: 1, inode: 2, size: size, mtimeNs: 5, ctimeNs: 6, mode: mode)
    }

    private func phase4NativeByteCount(_ session: ArchiveCursorLegacySession) throws -> Int64 {
        let database = try Phase4SQLiteDatabase(cursorLegacySession: session)
        return try database.query("SELECT value FROM cursorDiskKV").reduce(0) { total, row in
            total + Int64((row["value"] ?? nil)?.utf8.count ?? 0)
        }
    }

    private func provenanceContext(
        id: String = "owned",
        cwd: String = "",
        raw: Int64 = 2,
        native: Int64 = 2,
        wal: ArchiveSourceGeneration? = nil
    ) throws -> ArchiveCursorLegacyContext {
        try ArchiveCursorLegacyContext(
            databaseLocator: "/tmp/engram-cursor-legacy-replay/state.vscdb",
            composerID: id,
            cwd: cwd,
            rawPayloadByteCount: raw,
            nativePayloadByteCount: native,
            walGeneration: wal
        )
    }

    private func schemaSixManifest() throws -> ArchiveSourceManifest {
        let context = try provenanceContext(native: 6)
        let layout = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["session.cursor-legacy.json"],
            cursorLegacySession: context
        )
        return try ArchiveSourceManifest(
            schemaVersion: 6,
            captureID: captureDigest,
            machineID: machineID,
            source: "cursor",
            locator: context.logicalLocator,
            sessionID: nil,
            capturedAt: "2026-09-09T00:00:00.000Z",
            generation: try dbGeneration(size: 8_192),
            wholeSourceSHA256: sourceDigest,
            rawByteCount: 5,
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: chunkDigest, rawByteCount: 5)],
            replayLayout: layout
        )
    }

    private func schemaOneManifest() throws -> ArchiveSourceManifest {
        try ArchiveSourceManifest(
            schemaVersion: 1,
            captureID: captureDigest,
            machineID: machineID,
            source: "codex",
            locator: "/tmp/source.jsonl",
            sessionID: "session-1",
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: try dbGeneration(size: 5),
            wholeSourceSHA256: sourceDigest,
            rawByteCount: 5,
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: chunkDigest, rawByteCount: 5)],
            replayLayout: try ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["sessions/session.jsonl"])
        )
    }

    private func openCodeManifest() throws -> ArchiveSourceManifest {
        let context = try ArchiveSQLiteSessionContext(
            databaseLocator: "/source/opencode.db",
            nativeSessionID: "ses-one",
            nativePayloadByteCount: 2,
            walGeneration: nil
        )
        return try ArchiveSourceManifest(
            schemaVersion: 4,
            captureID: captureDigest,
            machineID: machineID,
            source: "opencode",
            locator: "/source/opencode.db::ses-one",
            sessionID: nil,
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: try dbGeneration(size: 8_192),
            wholeSourceSHA256: sourceDigest,
            rawByteCount: 5,
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: chunkDigest, rawByteCount: 5)],
            replayLayout: try ArchiveReplayLayout(
                strategy: .singleFile, relativePaths: ["session.sqlite"], sqliteSession: context
            )
        )
    }

    private func fileSetManifest() throws -> ArchiveSourceManifest {
        let generation = try dbGeneration(size: 5)
        let entry = try ArchiveFileSetEntry(
            relativePath: "chats/ws/id/store.db",
            byteOffset: 0,
            rawByteCount: 5,
            wholeSourceSHA256: sourceDigest,
            generation: generation
        )
        return try ArchiveSourceManifest(
            schemaVersion: 2,
            captureID: captureDigest,
            machineID: machineID,
            source: "cursor",
            locator: "/native/.cursor/chats/ws/id/store.db",
            sessionID: nil,
            capturedAt: "2026-09-08T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: sourceDigest,
            rawByteCount: 5,
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: chunkDigest, rawByteCount: 5)],
            replayLayout: try ArchiveReplayLayout(
                strategy: .fileSet,
                relativePaths: ["chats/ws/id/store.db"],
                entrypointRelativePath: "chats/ws/id/store.db",
                files: [entry],
                absentRelativePaths: ["chats/ws/id/store.db-wal"]
            )
        )
    }

    private func contextObject() throws -> [String: Any] {
        let encoded = try ArchiveCanonicalJSON.encode(try provenanceContext())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }

    // JSONSerialization.sortedKeys uses localized ordering (capturedAt before
    // captureID), unlike JSONEncoder's canonical UTF-8 key ordering.
    private func canonicalTestJSON(_ value: Any) throws -> String {
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return "{" + (try keys.map { try canonicalTestJSON($0) + ":" + canonicalTestJSON(object[$0]!) }).joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return "[" + (try array.map(canonicalTestJSON)).joined(separator: ",") + "]"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private func mutatingCanonical(_ bytes: Data, _ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        try mutate(&object)
        return Data(try canonicalTestJSON(object).utf8)
    }

    private func makeStore(_ storeRoot: URL) throws -> (ImmutableArchiveCAS, ArchiveCatalog) {
        let cas = try ImmutableArchiveCAS(root: storeRoot)
        let catalog = try ArchiveCatalog(root: storeRoot, machineID: machineID)
        try catalog.migrate()
        return (cas, catalog)
    }

    private func reconstruct(_ manifest: ArchiveSourceManifest, from cas: ImmutableArchiveCAS) throws -> Data {
        try manifest.chunks.reduce(into: Data()) { bytes, chunk in
            bytes.append(try cas.readObject(sha256: chunk.rawSHA256))
        }
    }
}

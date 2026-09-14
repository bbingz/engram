import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EngramCoreRead

final class ArchiveCursorLegacySessionTests: XCTestCase {
    func testRowStorageInferenceAndCanonicalRoundTrip() throws {
        let inferredNull = ArchiveCursorLegacySession.Row(rowID: 1, key: "composerData:owned", value: nil)
        let inferredText = ArchiveCursorLegacySession.Row(
            rowID: 1, key: "composerData:owned", value: Data(#"{"composerId":"owned"}"#.utf8)
        )
        XCTAssertEqual(inferredNull.storage, .null)
        XCTAssertEqual(inferredText.storage, .text)

        let session = try makeSession()
        XCTAssertEqual(session.kind, "cursorLegacyRowsV1")
        XCTAssertEqual(
            session.logicalLocator,
            "/tmp/engram-cursor-legacy-replay/state.vscdb?composer=owned"
        )
        XCTAssertEqual(session.rawPayloadByteCount, Int64(session.composer.value?.count ?? 0))
        let encoded = try session.encodeCanonical()
        let decoded = try ArchiveCursorLegacySession.decodeCanonical(encoded)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(try decoded.encodeCanonical(), encoded)
    }

    func testValidationRejectsPathIdentityCwdAndGeneration() throws {
        let regular = try generation()
        let directory = try generation(mode: 0o040755)
        let composer = textComposer()
        XCTAssertThrowsError(try makeSession(locator: "tmp/state.vscdb"))
        XCTAssertThrowsError(try makeSession(locator: "/tmp/state.vscdb?composer=owned"))
        XCTAssertThrowsError(try makeSession(locator: "/tmp/state.vscdb.bak"))
        XCTAssertThrowsError(try makeSession(locator: "/tmp/state.vscdb/extra"))
        XCTAssertThrowsError(try makeSession(locator: "/tmp/engram-cursor-legacy-replay/nested/../state.vscdb"))
        XCTAssertThrowsError(try makeSession(cwd: "/tmp/project/../escape"))
        XCTAssertThrowsError(try makeSession(id: ""))
        XCTAssertThrowsError(try makeSession(id: "id\0tail"))
        let maxID = String(repeating: "x", count: 4096)
        XCTAssertNoThrow(try makeSession(id: maxID))
        XCTAssertThrowsError(try makeSession(id: maxID + "x"))
        XCTAssertThrowsError(try makeSession(cwd: "/"))
        XCTAssertThrowsError(try makeSession(cwd: "relative/project"))
        XCTAssertThrowsError(try makeSession(cwd: "/tmp/project\0escape"))
        XCTAssertThrowsError(try ArchiveCursorLegacySession(
            logicalDatabaseLocator: "/tmp/engram-cursor-legacy-replay/state.vscdb",
            composerID: "owned", cwd: "", databaseGeneration: directory, walGeneration: nil,
            composer: composer, bubbles: []
        ))
        XCTAssertThrowsError(try ArchiveCursorLegacySession(
            logicalDatabaseLocator: "/tmp/engram-cursor-legacy-replay/state.vscdb",
            composerID: "owned", cwd: "", databaseGeneration: regular, walGeneration: directory,
            composer: composer, bubbles: []
        ))
    }

    func testValidationRejectsScopeOrderDuplicatesAndEmbeddedBubbles() {
        let extra = ArchiveCursorLegacySession.Row(
            rowID: 3, key: "bubbleId:owned:1", value: Data(#"{"type":1,"text":"x"}"#.utf8)
        )
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        XCTAssertNoThrow(try makeSession(id: nfc))
        XCTAssertThrowsError(try makeSession(
            id: nfc,
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:\(nfd)", value: Data(#"{"composerId":"\#(nfc)"}"#.utf8)
            )
        ))
        XCTAssertThrowsError(try makeSession(
            id: nfc,
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:\(nfc)", value: Data(#"{"composerId":"\#(nfd)"}"#.utf8)
            )
        ))
        XCTAssertThrowsError(try makeSession(
            id: nfc,
            bubbles: [
                ArchiveCursorLegacySession.Row(
                    rowID: 2, key: "bubbleId:\(nfd):1", value: Data(#"{"type":1,"text":"x"}"#.utf8)
                ),
            ]
        ))
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:other", value: Data(#"{"composerId":"owned"}"#.utf8)
            )
        ))
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:owned", value: Data(#"{"composerId":"other"}"#.utf8)
            )
        ))
        XCTAssertThrowsError(try makeSession(bubbles: [
            ArchiveCursorLegacySession.Row(
                rowID: 2, key: "bubbleId:other:1", value: Data(#"{"type":1,"text":"x"}"#.utf8)
            ),
        ]))
        XCTAssertThrowsError(try makeSession(bubbles: [extra, extra]))
        XCTAssertThrowsError(try makeSession(bubbles: [
            ArchiveCursorLegacySession.Row(
                rowID: 4, key: "bubbleId:owned:2", value: Data(#"{"type":1,"text":"later"}"#.utf8)
            ),
            extra,
        ]))
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(
                rowID: 3, key: "composerData:owned", value: Data(#"{"composerId":"owned"}"#.utf8)
            ),
            bubbles: [extra]
        ))
        let embedded = #"{"composerId":"owned","conversation":[{"type":1,"text":"keep"}]}"#
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(rowID: 1, key: "composerData:owned", value: Data(embedded.utf8)),
            bubbles: [extra]
        ))
    }

    func testValidationRejectsBudgetsAndStorageNullMismatch() {
        let exactValue = Data(count: 16 * 1024 * 1024 - (textComposer().value?.count ?? 0))
        XCTAssertNoThrow(try makeSession(bubbles: [
            ArchiveCursorLegacySession.Row(
                rowID: 2, key: "bubbleId:owned:exact", value: exactValue, storage: .blob
            ),
        ]))
        XCTAssertThrowsError(try makeSession(bubbles: [
            ArchiveCursorLegacySession.Row(
                rowID: 2, key: "bubbleId:owned:exact", value: exactValue + Data([0]), storage: .blob
            ),
        ]))
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:owned", value: Data(count: exactValue.count + 1), storage: .blob
            )
        ))
        let composerKey = "composerData:owned"
        let bubblePrefix = "bubbleId:owned:"
        let exactKeyPad = 16 * 1024 * 1024 - composerKey.utf8.count - bubblePrefix.utf8.count
        XCTAssertNoThrow(try makeSession(bubbles: [
            ArchiveCursorLegacySession.Row(
                rowID: 2,
                key: bubblePrefix + String(repeating: "k", count: exactKeyPad),
                value: Data(#"{"type":1,"text":"x"}"#.utf8)
            ),
        ]))
        XCTAssertThrowsError(try makeSession(bubbles: [
            ArchiveCursorLegacySession.Row(
                rowID: 2, key: bubblePrefix + String(repeating: "k", count: exactKeyPad + 1), value: nil
            ),
        ]))
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1,
                key: composerKey + String(repeating: "k", count: 16 * 1024 * 1024),
                value: Data(#"{"composerId":"owned"}"#.utf8)
            )
        ))
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:owned", value: Data(#"{"composerId":"owned"}"#.utf8), storage: .null
            )
        ))
        XCTAssertThrowsError(try makeSession(
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:owned", value: nil, storage: .text
            )
        ))
        var atRowLimit: [ArchiveCursorLegacySession.Row] = []
        atRowLimit.reserveCapacity(16_383)
        for index in 0..<16_383 {
            atRowLimit.append(ArchiveCursorLegacySession.Row(
                rowID: Int64(index + 2),
                key: "bubbleId:owned:\(index)",
                value: Data(#"{"type":1,"text":"n"}"#.utf8)
            ))
        }
        XCTAssertNoThrow(try makeSession(bubbles: atRowLimit))
        var overRowLimit = atRowLimit
        overRowLimit.append(ArchiveCursorLegacySession.Row(
            rowID: 16_385,
            key: "bubbleId:owned:over",
            value: Data(#"{"type":1,"text":"n"}"#.utf8)
        ))
        XCTAssertThrowsError(try makeSession(bubbles: overRowLimit))
    }

    func testCanonicalDecodeRejectsWrongKindUnknownAndReboundCounts() throws {
        let encoded = try makeSession().encodeCanonical()
        XCTAssertEqual(try mutatingCanonical(encoded) { _ in }, encoded)
        let wrongKind = try mutatingCanonical(encoded) { $0["kind"] = "opencodeSessionImage" }
        XCTAssertThrowsError(try ArchiveCursorLegacySession.decodeCanonical(wrongKind))
        let unknown = try mutatingCanonical(encoded) { $0["zzzUnknown"] = true }
        XCTAssertThrowsError(try ArchiveCursorLegacySession.decodeCanonical(unknown))
        let rebound = try mutatingCanonical(encoded) { object in
            let current = object["rawPayloadByteCount"] as? Int ?? 0
            object["rawPayloadByteCount"] = current + 1
        }
        XCTAssertThrowsError(try ArchiveCursorLegacySession.decodeCanonical(rebound))
    }

    func testCapturedReplayMatchesLiveNativeAfterSourceRemoval() async throws {
        let live = try LiveCursorFixture()
        defer { live.close() }
        let folder = "file:///tmp/engram-cursor-legacy-replay/owned"
        let composer = #"{"composerId":"owned","createdAt":1700000000000,"lastUpdatedAt":1700000001000,"title":"Replay"}"#
        let user = #"{"type":1,"text":"hello user","timingInfo":{"clientStartTime":1700000000000}}"#
        let assistant = #"{"type":2,"text":"hello assistant","tokenCount":{"inputTokens":3,"outputTokens":5}}"#
        try live.insertComposer("owned", json: composer)
        try live.insertBubble(id: "owned", suffix: "1", json: user)
        try live.insertBubble(id: "owned", suffix: "2", json: assistant)
        try live.addWorkspace("ws-a", folderURI: folder, composerID: "owned")
        try live.flush()

        let adapter = CursorAdapter(dbPath: live.database.path)
        let locator = live.database.path + "?composer=owned"
        guard case .success(let native) = try await adapter.scanForIndexing(locator: locator) else {
            return XCTFail("live native scan must succeed")
        }
        XCTAssertEqual(native.info.cwd, Self.cwd(folder))
        XCTAssertEqual(native.info.filePath, locator)
        XCTAssertEqual(native.messages.count, 2)
        XCTAssertEqual(native.messages[1].usage?.inputTokens, 3)
        XCTAssertEqual(native.messages[1].usage?.outputTokens, 5)

        let session = try ArchiveCursorLegacySession(
            logicalDatabaseLocator: live.database.path,
            composerID: "owned",
            cwd: Self.cwd(folder),
            databaseGeneration: try live.generation(of: live.database),
            walGeneration: try live.walGeneration(),
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:owned", value: Data(composer.utf8)
            ),
            bubbles: [
                ArchiveCursorLegacySession.Row(rowID: 2, key: "bubbleId:owned:1", value: Data(user.utf8)),
                ArchiveCursorLegacySession.Row(rowID: 3, key: "bubbleId:owned:2", value: Data(assistant.utf8)),
            ]
        )
        let encoded = try session.encodeCanonical()
        let persisted = try live.persistCanonicalOutsideUser(encoded)
        XCTAssertFalse(persisted.path.hasPrefix(live.userRoot.path + "/"))
        live.removeUserTree()
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.userRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted.path))

        let decoded = try ArchiveCursorLegacySession.decodeCanonical(Data(contentsOf: persisted))
        XCTAssertEqual(decoded.logicalLocator, locator)
        guard case .success(let captured) = try await CursorAdapter.scanCapturedLegacySession(
            decoded, logicalLocator: decoded.logicalLocator
        ) else {
            return XCTFail("captured replay must succeed after the live User tree is gone")
        }
        XCTAssertEqual(captured.rawSourceSessionID, "owned")
        XCTAssertEqual(captured.scan.info.id, native.info.id)
        XCTAssertEqual(captured.scan.info.cwd, native.info.cwd)
        XCTAssertEqual(captured.scan.info.project, native.info.project)
        XCTAssertEqual(captured.scan.info.displayTitle, native.info.displayTitle)
        XCTAssertEqual(captured.scan.info.startTime, native.info.startTime)
        XCTAssertEqual(captured.scan.info.endTime, native.info.endTime)
        XCTAssertEqual(captured.scan.info.messageCount, native.info.messageCount)
        XCTAssertEqual(captured.scan.info.userMessageCount, native.info.userMessageCount)
        XCTAssertEqual(captured.scan.info.assistantMessageCount, native.info.assistantMessageCount)
        XCTAssertEqual(captured.scan.info.sizeBytes, native.info.sizeBytes)
        XCTAssertEqual(captured.scan.info.filePath, decoded.logicalLocator)
        XCTAssertEqual(captured.scan.messages, native.messages)
        XCTAssertGreaterThan(decoded.rawPayloadByteCount, 0)
    }

    func testTextBlobNulInvalidUTF8AndNullPreserveNativeLossAndRawCount() async throws {
        let live = try LiveCursorFixture()
        defer { live.close() }
        let composer = #"{"composerId":"owned"}"#
        let visible = #"{"type":1,"text":"keep"}"#
        let blobHello = Data(#"{"type":2,"text":"hello"}"#.utf8)
        let nul = Data("pre".utf8) + Data([0]) + Data("post".utf8)
        let invalid = Data([0x61, 0xFF, 0xFE, 0x80])
        try live.insertComposer("owned", json: composer)
        try live.insertBubble(id: "owned", suffix: "keep", json: visible)
        try live.insertBlob(key: "bubbleId:owned:hello", value: blobHello)
        try live.insertBlob(key: "bubbleId:owned:nul", value: nul)
        try live.insertBlob(key: "bubbleId:owned:invalid", value: invalid)
        try live.insertNull(key: "bubbleId:owned:empty")
        try live.flush()

        let adapter = CursorAdapter(dbPath: live.database.path)
        let locator = live.database.path + "?composer=owned"
        guard case .success(let native) = try await adapter.scanForIndexing(locator: locator) else {
            return XCTFail("live native scan must succeed")
        }

        let session = try ArchiveCursorLegacySession(
            logicalDatabaseLocator: live.database.path,
            composerID: "owned",
            cwd: "",
            databaseGeneration: try live.generation(of: live.database),
            walGeneration: try live.walGeneration(),
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
        XCTAssertEqual(
            session.rawPayloadByteCount,
            Int64(composer.utf8.count + visible.utf8.count + blobHello.count + nul.count + invalid.count)
        )
        XCTAssertNotEqual(session.rawPayloadByteCount, native.info.sizeBytes)

        let encoded = try session.encodeCanonical()
        live.removeUserTree()
        let decoded = try ArchiveCursorLegacySession.decodeCanonical(encoded)
        guard case .success(let captured) = try await CursorAdapter.scanCapturedLegacySession(
            decoded, logicalLocator: decoded.logicalLocator
        ) else {
            return XCTFail("captured replay must succeed")
        }
        XCTAssertEqual(captured.scan.info.sizeBytes, native.info.sizeBytes)
        XCTAssertEqual(captured.scan.messages, native.messages)
        XCTAssertEqual(captured.scan.info.cwd, "")
        XCTAssertNotEqual(decoded.rawPayloadByteCount, captured.scan.info.sizeBytes)
    }

    func testEmbeddedConversationMessageCapAndWrongLogicalLocator() async throws {
        let live = try LiveCursorFixture()
        defer { live.close() }
        let composer = #"{"composerId":"embed","conversation":[{"type":1,"text":"first"},{"type":2,"text":"second"}]}"#
        try live.insertComposer("embed", json: composer)
        _ = try live.insertBubble(id: "embed", suffix: "ignored", json: #"{"type":1,"text":"must-not-stream"}"#)
        try live.flush()

        let adapter = CursorAdapter(dbPath: live.database.path)
        let locator = live.database.path + "?composer=embed"
        guard case .success(let native) = try await adapter.scanForIndexing(locator: locator) else {
            return XCTFail("embedded live scan must succeed")
        }
        XCTAssertEqual(native.messages.map(\.content), ["first", "second"])
        XCTAssertEqual(native.info.sizeBytes, Int64(composer.utf8.count))

        let limited = CursorAdapter(dbPath: live.database.path, limits: ParserLimits(maxMessages: 1))
        guard case .failure(let limitFailure) = try await limited.scanForIndexing(locator: locator) else {
            return XCTFail("live message cap must fail closed")
        }
        XCTAssertEqual(limitFailure, .messageLimitExceeded)

        let session = try ArchiveCursorLegacySession(
            logicalDatabaseLocator: live.database.path,
            composerID: "embed",
            cwd: "",
            databaseGeneration: try live.generation(of: live.database),
            walGeneration: try live.walGeneration(),
            composer: ArchiveCursorLegacySession.Row(
                rowID: 1, key: "composerData:embed", value: Data(composer.utf8)
            ),
            bubbles: []
        )
        XCTAssertEqual(session.rawPayloadByteCount, Int64(composer.utf8.count))
        let encoded = try session.encodeCanonical()
        live.removeUserTree()
        let decoded = try ArchiveCursorLegacySession.decodeCanonical(encoded)

        guard case .success(let captured) = try await CursorAdapter.scanCapturedLegacySession(
            decoded, logicalLocator: decoded.logicalLocator
        ) else {
            return XCTFail("embedded captured replay must succeed")
        }
        XCTAssertEqual(captured.scan.messages, native.messages)
        XCTAssertEqual(captured.scan.info.sizeBytes, native.info.sizeBytes)

        guard case .failure(let capturedCap) = try await CursorAdapter.scanCapturedLegacySession(
            decoded, logicalLocator: decoded.logicalLocator, limits: ParserLimits(maxMessages: 1)
        ) else {
            return XCTFail("captured message cap must fail closed")
        }
        XCTAssertEqual(capturedCap, .messageLimitExceeded)

        do {
            let result = try await CursorAdapter.scanCapturedLegacySession(
                decoded, logicalLocator: decoded.logicalLocator + "-wrong"
            )
            if case .success = result {
                XCTFail("wrong logical locator must not replay")
            }
        } catch {}
    }

    func testCapturedRowsIgnoreExistingLiveDatabaseAndPreserveZeroNegativeRowIDs() async throws {
        let live = try LiveCursorFixture()
        defer { live.close() }
        try live.insertComposer("owned", json: #"{"composerId":"owned","conversation":[{"type":1,"text":"wrong-live"}]}"#)
        try live.addWorkspace("ws", folderURI: "file:///tmp/wrong-live-project", composerID: "owned")
        try live.flush()
        let body = try makeSession(locator: live.database.path, cwd: "/tmp/frozen-project",
            composer: .init(rowID: 0, key: "composerData:owned", value: textComposer().value),
            bubbles: [
                .init(rowID: -10, key: "bubbleId:owned:first", value: Data(#"{"type":1,"text":"captured"}"#.utf8)),
                .init(rowID: -9, key: "bubbleId:owned:empty-text", value: Data(), storage: .text),
                .init(rowID: -8, key: "bubbleId:owned:empty-blob", value: Data(), storage: .blob),
                .init(rowID: -7, key: "bubbleId:owned:null", value: nil),
            ])
        let decoded = try ArchiveCursorLegacySession.decodeCanonical(body.encodeCanonical())
        let database = try Phase4SQLiteDatabase(cursorLegacySession: decoded)
        let types = try database.query("SELECT rowid, typeof(value) AS storage FROM cursorDiskKV ORDER BY rowid")
        XCTAssertEqual(types.compactMap { $0["storage"] ?? nil }, ["text", "text", "blob", "null", "text"])
        XCTAssertEqual(types.compactMap { $0["rowid"] ?? nil }, ["-10", "-9", "-8", "-7", "0"])
        guard case .success(let captured) = try await CursorAdapter.scanCapturedLegacySession(
            decoded, logicalLocator: decoded.logicalLocator
        ) else { return XCTFail("capture must ignore surviving live metadata and messages") }
        XCTAssertEqual(captured.scan.messages.map(\.content), ["captured"])
        XCTAssertEqual(captured.scan.info.cwd, "/tmp/frozen-project")
        guard case .failure(let failure) = try await CursorAdapter.scanCapturedLegacySession(
            decoded, logicalLocator: decoded.logicalLocator,
            limits: ParserLimits(maxFileBytes: decoded.rawPayloadByteCount - 1)
        ) else { return XCTFail("raw byte limit must fail closed") }
        XCTAssertEqual(failure, .fileTooLarge)
    }

    private static func cwd(_ folderURI: String) -> String {
        URL(string: folderURI)?.standardizedFileURL.path ?? ""
    }

    private func generation(mode: Int64 = 33_188) throws -> ArchiveSourceGeneration {
        try ArchiveSourceGeneration(device: 1, inode: 2, size: 64, mtimeNs: 5, ctimeNs: 6, mode: mode)
    }

    private func textComposer(id: String = "owned") -> ArchiveCursorLegacySession.Row {
        ArchiveCursorLegacySession.Row(
            rowID: 1, key: "composerData:\(id)", value: Data(#"{"composerId":"\#(id)"}"#.utf8)
        )
    }

    private func makeSession(
        locator: String = "/tmp/engram-cursor-legacy-replay/state.vscdb",
        id: String = "owned",
        cwd: String = "",
        composer: ArchiveCursorLegacySession.Row? = nil,
        bubbles: [ArchiveCursorLegacySession.Row] = []
    ) throws -> ArchiveCursorLegacySession {
        try ArchiveCursorLegacySession(
            logicalDatabaseLocator: locator,
            composerID: id,
            cwd: cwd,
            databaseGeneration: try generation(),
            walGeneration: nil,
            composer: composer ?? textComposer(id: id),
            bubbles: bubbles
        )
    }

    private func mutatingCanonical(
        _ bytes: Data, _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private final class LiveCursorFixture {
    let base: URL
    let userRoot: URL
    let database: URL
    private var writer: OpaquePointer?
    private var workspaceWriter: OpaquePointer?

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cursor-legacy-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        userRoot = base.appendingPathComponent("User")
        let globalStorage = userRoot.appendingPathComponent("globalStorage")
        try FileManager.default.createDirectory(
            at: globalStorage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        database = globalStorage.appendingPathComponent("state.vscdb")
        writer = try Self.open(database)
        try sql(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try sql(writer, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);")
    }

    func insertComposer(_ id: String, json: String) throws {
        try insert(key: "composerData:\(id)", value: Data(json.utf8), asBlob: false)
    }

    @discardableResult
    func insertBubble(id: String, suffix: String, json: String) throws -> Int64 {
        try insert(key: "bubbleId:\(id):\(suffix)", value: Data(json.utf8), asBlob: false)
    }

    func insertBlob(key: String, value: Data) throws {
        _ = try insert(key: key, value: value, asBlob: true)
    }

    func insertNull(key: String) throws {
        _ = try insert(key: key, value: nil, asBlob: false)
    }

    func addWorkspace(_ id: String, folderURI: String, composerID: String) throws {
        let directory = userRoot.appendingPathComponent("workspaceStorage").appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try Data(#"{"folder":"\#(folderURI)"}"#.utf8)
            .write(to: directory.appendingPathComponent("workspace.json"))
        workspaceWriter = try Self.open(directory.appendingPathComponent("state.vscdb"))
        try sql(workspaceWriter, "PRAGMA journal_mode=WAL;")
        try sql(workspaceWriter, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")
        try bind(
            workspaceWriter,
            "INSERT INTO ItemTable(key, value) VALUES (?, ?)",
            key: Data("composer.composerData".utf8),
            value: Data(#"{"allComposers":[{"composerId":"\#(composerID)"}]}"#.utf8),
            asBlob: false
        )
    }

    func flush() throws {
        try flush(writer)
        try flush(workspaceWriter)
    }

    func walGeneration() throws -> ArchiveSourceGeneration? {
        let wal = URL(fileURLWithPath: database.path + "-wal")
        guard FileManager.default.fileExists(atPath: wal.path) else { return nil }
        return try generation(of: wal)
    }

    func generation(of url: URL) throws -> ArchiveSourceGeneration {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let inode = Int64(exactly: info.st_ino) else { throw POSIXError(.EIO) }
        func nanos(_ time: timespec) throws -> Int64 {
            let seconds = Int64(time.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let result = seconds.partialValue.addingReportingOverflow(Int64(time.tv_nsec))
            guard !seconds.overflow, !result.overflow else { throw POSIXError(.EOVERFLOW) }
            return result.partialValue
        }
        return try ArchiveSourceGeneration(
            device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
            mtimeNs: nanos(info.st_mtimespec), ctimeNs: nanos(info.st_ctimespec), mode: Int64(info.st_mode)
        )
    }

    func persistCanonicalOutsideUser(_ bytes: Data) throws -> URL {
        let url = base.appendingPathComponent("canonical-body.json")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    func removeUserTree() {
        stop()
        try? FileManager.default.removeItem(at: userRoot)
    }

    func close() {
        stop()
        try? FileManager.default.removeItem(at: base)
    }

    private func insert(key: String, value: Data?, asBlob: Bool) throws -> Int64 {
        try bind(
            writer, "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)",
            key: Data(key.utf8), value: value, asBlob: asBlob
        )
        return sqlite3_last_insert_rowid(try XCTUnwrap(writer))
    }

    private func bind(
        _ handle: OpaquePointer?, _ sql: String, key: Data, value: Data?, asBlob: Bool
    ) throws {
        guard let handle else { throw POSIXError(.EIO) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try key.withUnsafeBytes { buffer in
            guard sqlite3_bind_text(
                statement, 1, buffer.bindMemory(to: Int8.self).baseAddress, Int32(key.count), transient
            ) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        if let value {
            try value.withUnsafeBytes { buffer in
                let status = asBlob
                    ? sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(value.count), transient)
                    : sqlite3_bind_text(
                        statement, 2, buffer.bindMemory(to: Int8.self).baseAddress, Int32(value.count), transient
                    )
                guard status == SQLITE_OK else { throw POSIXError(.EIO) }
            }
        } else {
            guard sqlite3_bind_null(statement, 2) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw POSIXError(.EIO) }
    }

    private func sql(_ handle: OpaquePointer?, _ value: String) throws {
        guard let handle else { throw POSIXError(.EIO) }
        var errmsg: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, value, nil, nil, &errmsg)
        let message = errmsg.map { String(cString: $0) }
        sqlite3_free(errmsg)
        guard status == SQLITE_OK else {
            throw NSError(
                domain: "LiveCursorFixture.sql", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message ?? "sqlite3_exec"]
            )
        }
    }

    private func flush(_ handle: OpaquePointer?) throws {
        guard let handle else { return }
        guard sqlite3_db_cacheflush(handle) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    private func stop() {
        if let writer {
            XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
            self.writer = nil
        }
        if let workspaceWriter {
            XCTAssertEqual(sqlite3_close(workspaceWriter), SQLITE_OK)
            self.workspaceWriter = nil
        }
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw POSIXError(.EIO) }
        return handle
    }
}

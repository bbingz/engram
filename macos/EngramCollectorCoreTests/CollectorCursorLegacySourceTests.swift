import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EngramCollectorCore

/// Raw-row `exportRows` only. Not upload authorization; no message parse or cwd freeze.
final class CollectorCursorLegacySourceTests: XCTestCase {
    func testExportRowsKeepsExactComposerAndRowidOrderedOwnedBubblesWithoutSiblingRows_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let ownedComposer = #"{"composerId":"owned"}"#
        let ownedZ = #"{"type":2,"text":"later-key-first-rowid"}"#
        let ownedMalformed = "{not-json"
        let ownedLate = #"{"type":1,"text":"after-null"}"#
        let owned = try fixture.insertOwnedAndSibling(
            composer: ownedComposer, firstBubble: ownedZ, malformed: ownedMalformed, lateBubble: ownedLate
        )

        let exported = try fixture.exportRows("owned")
        XCTAssertEqual(exported.composerID, "owned")
        XCTAssertEqual(exported.composer, owned.composer)
        XCTAssertEqual(exported.bubbles, owned.bubbles)
        XCTAssertEqual(exported.bubbles.map(\.key), [
            "bubbleId:owned:z", "bubbleId:owned:malformed", "bubbleId:owned:null", "bubbleId:owned:late",
        ])
        XCTAssertNil(exported.bubbles[2].value)
        XCTAssertEqual(exported.bubbles[2].storage, .null)
        XCTAssertEqual(exported.bubbles[1].value, Data(ownedMalformed.utf8))
        XCTAssertEqual(exported.rawPayloadByteCount, owned.payloadBytes)
        XCTAssertFalse(exported.bubbles.contains { $0.key.contains("sibling") })
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testEmbeddedNonemptyConversationExportsZeroBubbleRowsAndBytes_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let composer = #"{"composerId":"embed","conversation":[{"type":1,"text":"keep-raw"}]}"#
        let composerRow = try fixture.insert(key: "composerData:embed", value: composer)
        _ = try fixture.insert(key: "bubbleId:embed:x", value: #"{"type":2,"text":"must-not-export"}"#)
        _ = try fixture.insert(key: "composerData:other", value: #"{"composerId":"other"}"#)
        try fixture.flush()

        let exported = try fixture.exportRows("embed")
        XCTAssertEqual(exported.composerID, "embed")
        XCTAssertEqual(exported.composer.rowID, composerRow)
        XCTAssertEqual(exported.composer.key, "composerData:embed")
        XCTAssertEqual(exported.composer.value, Data(composer.utf8))
        XCTAssertEqual(exported.bubbles, [])
        XCTAssertEqual(exported.rawPayloadByteCount, Int64(composer.utf8.count))
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testLiteralPercentUnderscoreCaseAndUnicodeComposerIDsExportSeparately_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        // Swift String == is canonical; NFC/NFD must stay distinct as UTF-8 bytes.
        let nfc = Data("id".utf8) + Data([0xC3, 0xA9])
        let nfd = Data("id".utf8) + Data([0x65, 0xCC, 0x81])
        XCTAssertNotEqual(nfc, nfd)
        let ids = [Data("id".utf8), Data("id%".utf8), Data("id_".utf8), Data("Id".utf8), nfc, nfd]
        var expected: [Data: (composerRowID: Int64, composerKey: Data, composerValue: Data,
                              bubbleRowID: Int64, bubbleKey: Data, bubbleValue: Data)] = [:]
        for id in ids {
            let composerKey = Data("composerData:".utf8) + id
            let bubbleKey = Data("bubbleId:".utf8) + id + Data(":1".utf8)
            let composerValue = Data(#"{"composerId":""#.utf8) + id + Data(#""}"#.utf8)
            let bubbleValue = Data(#"{"type":1,"text":"payload:""#.utf8) + id + Data(#""}"#.utf8)
            let composerRow = try fixture.insert(key: composerKey, value: composerValue)
            let bubbleRow = try fixture.insert(key: bubbleKey, value: bubbleValue)
            expected[id] = (composerRow, composerKey, composerValue, bubbleRow, bubbleKey, bubbleValue)
        }
        try fixture.flush()

        for id in ids {
            let rows = try XCTUnwrap(expected[id])
            let exported = try fixture.exportRows(utf8: id)
            XCTAssertEqual(Data(exported.composerID.utf8), id)
            XCTAssertEqual(Data(exported.composer.key.utf8), rows.composerKey)
            XCTAssertEqual(exported.composer.rowID, rows.composerRowID)
            XCTAssertEqual(exported.composer.value, rows.composerValue)
            XCTAssertEqual(exported.bubbles.count, 1)
            let bubble = try XCTUnwrap(exported.bubbles.first)
            XCTAssertEqual(Data(bubble.key.utf8), rows.bubbleKey)
            XCTAssertEqual(bubble.rowID, rows.bubbleRowID)
            XCTAssertEqual(bubble.value, rows.bubbleValue)
            XCTAssertEqual(exported.rawPayloadByteCount, Int64(rows.composerValue.count + rows.bubbleValue.count))
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testComposerKeyMismatchAndDelimiterAmbiguousOwnershipFailClosed_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        _ = try fixture.insert(key: "composerData:asked", value: #"{"composerId":"other"}"#)
        _ = try fixture.insert(key: "composerData:foo", value: #"{"composerId":"foo"}"#)
        _ = try fixture.insert(key: "composerData:foo:bar", value: #"{"composerId":"foo:bar"}"#)
        _ = try fixture.insert(key: "bubbleId:foo:1", value: #"{"type":1,"text":"short"}"#)
        _ = try fixture.insert(key: "bubbleId:foo:bar:1", value: #"{"type":1,"text":"overlap"}"#)
        try fixture.flush()

        assertLegacy(.invalidComposer) { try fixture.exportRows("asked") }
        assertLegacy(.invalidComposer) { try fixture.exportRows("missing") }
        assertLegacy(.ambiguousScope) { try fixture.exportRows("foo") }
        assertLegacy(.ambiguousScope) { try fixture.exportRows("foo:bar") }

        let colonOnly = try LegacyRowFixture()
        defer { colonOnly.close() }
        let colonComposer = #"{"composerId":"a:b"}"#
        let colonBubble = #"{"type":1,"text":"colon-only"}"#
        let composerRow = try colonOnly.insert(key: "composerData:a:b", value: colonComposer)
        let bubbleRow = try colonOnly.insert(key: "bubbleId:a:b:1", value: colonBubble)
        try colonOnly.flush()
        let exported = try colonOnly.exportRows("a:b")
        XCTAssertEqual(exported.composer, CollectorCursorLegacySource.Row(
            rowID: composerRow, key: "composerData:a:b", value: Data(colonComposer.utf8)
        ))
        XCTAssertEqual(exported.bubbles, [
            CollectorCursorLegacySource.Row(rowID: bubbleRow, key: "bubbleId:a:b:1", value: Data(colonBubble.utf8)),
        ])

        let shortOnly = try LegacyRowFixture()
        defer { shortOnly.close() }
        let shortComposer = #"{"composerId":"foo"}"#
        let shortBubble = #"{"type":1,"text":"named-bar"}"#
        _ = try shortOnly.insert(key: "composerData:foo", value: shortComposer)
        let owned = try shortOnly.insert(key: "bubbleId:foo:bar:1", value: shortBubble)
        try shortOnly.flush()
        let shortExport = try shortOnly.exportRows("foo")
        XCTAssertEqual(shortExport.bubbles, [
            CollectorCursorLegacySource.Row(rowID: owned, key: "bubbleId:foo:bar:1", value: Data(shortBubble.utf8)),
        ])
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
        XCTAssertTrue(try colonOnly.stagingNames().isEmpty)
        XCTAssertTrue(try shortOnly.stagingNames().isEmpty)
    }

    func testRowByteAndSQLiteStepBudgetsRejectFullExportInsteadOfPrefix_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let owned = try fixture.insertOwnedAndSibling()
        let full = try fixture.exportRows("owned")
        XCTAssertEqual(full.bubbles.count, 4)
        XCTAssertEqual(full.rawPayloadByteCount, owned.payloadBytes)
        XCTAssertGreaterThan(full.rawPayloadByteCount, 1)

        assertLegacy(.exceededBudget) {
            try fixture.exportRows("owned", budget: .init(maximumRows: 1))
        }
        assertLegacy(.exceededBudget) {
            try fixture.exportRows("owned", budget: .init(maximumOutputBytes: full.rawPayloadByteCount - 1))
        }
        assertLegacy(.exceededBudget) {
            try fixture.exportRows("owned", budget: .init(maximumSQLiteSteps: 1))
        }
        let again = try fixture.exportRows("owned")
        XCTAssertEqual(again.composer, full.composer)
        XCTAssertEqual(again.bubbles, full.bubbles)
        XCTAssertEqual(again.rawPayloadByteCount, full.rawPayloadByteCount)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testHeldWriterWALOnlyRowsExportWithoutTouchingSourceBytesOrGenerations_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        try fixture.prepareEmptyWALSchema()
        let checkpointedMain = try Data(contentsOf: fixture.database)
        let composer = #"{"composerId":"wal-only"}"#
        let bubble = #"{"type":1,"text":"from-wal"}"#
        let composerRow = try fixture.insert(key: "composerData:wal-only", value: composer)
        let bubbleRow = try fixture.insert(key: "bubbleId:wal-only:1", value: bubble)
        try fixture.flush()

        let before = try fixture.sourceBytes()
        XCTAssertEqual(before[""], checkpointedMain)
        XCTAssertGreaterThan(try XCTUnwrap(before["-wal"]).count, 32)
        let mainGeneration = try fixture.generation(of: fixture.database)
        let walGeneration = try fixture.generation(of: fixture.wal)
        var opened: [URL] = []
        var rowsRead = false
        let exported = try fixture.exportRows(
            "wal-only",
            testHooks: .init(
                beforeSQLiteOpen: { opened.append($0) },
                afterRowsRead: { rowsRead = true }
            )
        )

        XCTAssertEqual(exported.composerID, "wal-only")
        XCTAssertEqual(exported.composer, CollectorCursorLegacySource.Row(
            rowID: composerRow, key: "composerData:wal-only", value: Data(composer.utf8)
        ))
        XCTAssertEqual(exported.bubbles, [
            CollectorCursorLegacySource.Row(rowID: bubbleRow, key: "bubbleId:wal-only:1", value: Data(bubble.utf8)),
        ])
        XCTAssertEqual(exported.rawPayloadByteCount, Int64(composer.utf8.count + bubble.utf8.count))
        XCTAssertEqual(exported.databaseGeneration, mainGeneration)
        XCTAssertEqual(exported.walGeneration, walGeneration)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(try XCTUnwrap(opened.first).path.hasPrefix(fixture.staging.path + "/"))
        XCTAssertFalse(try XCTUnwrap(opened.first).path.hasPrefix(fixture.source.path + "/"))
        XCTAssertTrue(rowsRead)
        XCTAssertEqual(try fixture.sourceBytes(), before)
        XCTAssertEqual(try fixture.generation(of: fixture.database), mainGeneration)
        XCTAssertEqual(try fixture.generation(of: fixture.wal), walGeneration)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testPrivateDatabaseMutationAndReplacementBeforeSQLiteOpenIsRejected_repro() throws {
        for kind in ["mutate", "replace-symlink"] {
            let fixture = try LegacyRowFixture()
            defer { fixture.close() }
            _ = try fixture.insertOwnedAndSibling()
            let before = try fixture.sourceBytes()
            assertLegacy(.sourceChanged) {
                try fixture.exportRows("owned", testHooks: .init(beforeSQLiteOpen: { url in
                    if kind == "mutate" {
                        try Data("tampered-private-main".utf8).write(to: url)
                    } else {
                        try FileManager.default.removeItem(at: url)
                        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.database)
                    }
                }))
            }
            XCTAssertEqual(try fixture.sourceBytes(), before)
            XCTAssertTrue(try fixture.stagingNames().isEmpty)
        }
    }

    func testPrivateDatabaseMutationAndReplacementAfterRowsReadIsRejected_repro() throws {
        for kind in ["mutate", "replace-symlink"] {
            let fixture = try LegacyRowFixture()
            defer { fixture.close() }
            _ = try fixture.insertOwnedAndSibling()
            let before = try fixture.sourceBytes()
            var privateURL: URL?
            assertLegacy(.sourceChanged) {
                try fixture.exportRows("owned", testHooks: .init(
                    beforeSQLiteOpen: { privateURL = $0 },
                    afterRowsRead: {
                        let url = try XCTUnwrap(privateURL)
                        if kind == "mutate" {
                            try Data("tampered-private-after-read".utf8).write(to: url)
                        } else {
                            try FileManager.default.removeItem(at: url)
                            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.database)
                        }
                    }
                ))
            }
            XCTAssertEqual(try fixture.sourceBytes(), before)
            XCTAssertTrue(try fixture.stagingNames().isEmpty)
        }
    }

    func testSourceWALChangeAfterRowsReadIsRejected_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        _ = try fixture.insertOwnedAndSibling()
        let before = try fixture.sourceBytes()
        assertLegacy(.sourceChanged) {
            try fixture.exportRows("owned", testHooks: .init(afterRowsRead: {
                _ = try fixture.insert(key: "composerData:late", value: #"{"composerId":"late"}"#)
                try fixture.flush()
            }))
        }
        XCTAssertNotEqual(try fixture.sourceBytes()["-wal"], before["-wal"])
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testSourceJournalAppearanceAndRootRebindingAfterRowsReadAreRejected_repro() throws {
        let journal = try LegacyRowFixture()
        defer { journal.close() }
        _ = try journal.insertOwnedAndSibling()
        let before = try journal.sourceBytes()
        assertLegacy(.sourceChanged) {
            try journal.exportRows("owned", testHooks: .init(afterRowsRead: {
                try Data("hot-rollback-journal".utf8).write(to: journal.journal)
            }))
        }
        XCTAssertEqual(try Data(contentsOf: journal.journal), Data("hot-rollback-journal".utf8))
        XCTAssertEqual(try journal.sourceBytes()[""], before[""])
        XCTAssertTrue(try journal.stagingNames().isEmpty)

        let rebound = try LegacyRowFixture()
        defer { rebound.close() }
        _ = try rebound.insertOwnedAndSibling()
        assertLegacy(.sourceChanged) {
            try rebound.exportRows("owned", testHooks: .init(afterRowsRead: {
                try rebound.rebindSourceRoot()
            }))
        }
        XCTAssertTrue(try rebound.stagingNames().isEmpty)
    }

    func testCheckpointedMainWithoutWALExportsOwnedRows_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let owned = try fixture.insertOwnedAndSibling()
        try fixture.disablePersistentWAL()
        try fixture.sql("PRAGMA wal_checkpoint(TRUNCATE)")
        fixture.stopWriter()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wal.path), "TRUNCATE then close must drop WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shm.path), "TRUNCATE then close must drop SHM")
        let before = try Data(contentsOf: fixture.database)
        XCTAssertEqual(try fixture.sourceNames(), ["state.vscdb"])

        let exported = try fixture.exportRows("owned")
        XCTAssertEqual(exported.composer, owned.composer)
        XCTAssertEqual(exported.bubbles, owned.bubbles)
        XCTAssertEqual(exported.rawPayloadByteCount, owned.payloadBytes)
        XCTAssertNil(exported.walGeneration)
        XCTAssertEqual(try Data(contentsOf: fixture.database), before)
        XCTAssertEqual(try fixture.sourceNames(), ["state.vscdb"])
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testOrdinaryCursorDiskKVWithItemTableExportsOwnedRows_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let owned = try fixture.insertOwnedAndSibling()
        try fixture.sql("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")
        _ = try fixture.insert(into: "ItemTable", key: "composer.composerHeaders", value: #"{"allComposers":[]}"#)
        try fixture.flush()
        let exported = try fixture.exportRows("owned")
        XCTAssertEqual(exported.composer, owned.composer)
        XCTAssertEqual(exported.bubbles, owned.bubbles)
        XCTAssertEqual(exported.rawPayloadByteCount, owned.payloadBytes)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testViewVirtualWithoutRowidAndGeneratedShadowRowidAreRejected_repro() throws {
        let view = try LegacyRowFixture(createDefaultTable: false)
        defer { view.close() }
        try view.sql("""
            CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT);
            CREATE VIEW cursorDiskKV AS
                SELECT key, value FROM kv
                UNION ALL SELECT 'bubbleId:owned:leak', '{"type":1,"text":"VIEW-LEAK"}';
            """)
        _ = try view.insert(into: "kv", key: "composerData:owned", value: #"{"composerId":"owned"}"#)
        _ = try view.insert(into: "kv", key: "bubbleId:owned:1", value: #"{"type":1,"text":"hidden"}"#)
        try view.flush()
        assertLegacy(.unsupportedSchema) { try view.exportRows("owned") }
        XCTAssertTrue(try view.stagingNames().isEmpty)

        let virtual = try LegacyRowFixture(createDefaultTable: false)
        defer { virtual.close() }
        try virtual.sql("CREATE VIRTUAL TABLE cursorDiskKV USING fts5(key, value);")
        _ = try virtual.insert(key: "composerData:owned", value: #"{"composerId":"owned"}"#)
        try virtual.flush()
        assertLegacy(.unsupportedSchema) { try virtual.exportRows("owned") }
        XCTAssertTrue(try virtual.stagingNames().isEmpty)

        let withoutRowid = try LegacyRowFixture(createDefaultTable: false)
        defer { withoutRowid.close() }
        try withoutRowid.sql("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;")
        _ = try withoutRowid.insert(key: "composerData:owned", value: #"{"composerId":"owned"}"#)
        try withoutRowid.flush()
        assertLegacy(.unsupportedSchema) { try withoutRowid.exportRows("owned") }
        XCTAssertTrue(try withoutRowid.stagingNames().isEmpty)

        let generated = try LegacyRowFixture(createDefaultTable: false)
        defer { generated.close() }
        XCTAssertNoThrow(try generated.sql("""
            CREATE TABLE cursorDiskKV (
                key TEXT PRIMARY KEY,
                value TEXT,
                rowid INTEGER GENERATED ALWAYS AS (length(key)) VIRTUAL
            );
            """))
        XCTAssertNoThrow(try generated.insert(key: "composerData:owned", value: #"{"composerId":"owned"}"#))
        try generated.flush()
        assertLegacy(.unsupportedSchema) { try generated.exportRows("owned") }
        XCTAssertTrue(try generated.stagingNames().isEmpty)
    }

    func testExactRawPayloadBudgetDoesNotChargeSQLiteSchemaOrRecordOverhead_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let raw = #"{"composerId":"x"}"#
        let rowID = try fixture.insert(key: "composerData:x", value: raw)
        try fixture.flush()
        let result = try fixture.exportRows("x", budget: .init(maximumOutputBytes: Int64(raw.utf8.count), maximumRows: 1))
        XCTAssertEqual(result.composer.rowID, rowID)
        XCTAssertEqual(result.composer.value, Data(raw.utf8))
        XCTAssertEqual(result.rawPayloadByteCount, Int64(raw.utf8.count))
        XCTAssertEqual(result.bubbles, [])
        assertLegacy(.exceededBudget) {
            try fixture.exportRows("x", budget: .init(maximumOutputBytes: Int64(raw.utf8.count - 1), maximumRows: 1))
        }
    }

    func testConstantGeneratedUppercaseROWIDCannotReplacePhysicalRowIdentity_repro() throws {
        let fixture = try LegacyRowFixture(createDefaultTable: false)
        defer { fixture.close() }
        try fixture.sql("""
            CREATE TABLE cursorDiskKV (
                key TEXT PRIMARY KEY, value TEXT,
                ROWID INTEGER GENERATED ALWAYS AS (7) VIRTUAL
            );
            """)
        _ = try fixture.insertOwnedAndSibling()
        assertLegacy(.unsupportedSchema) { try fixture.exportRows("owned") }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testTextValuesRetainInvalidUTF8NULAndUTF16LogicalUTF8Bytes_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let composer = #"{"composerId":"owned"}"#
        let invalidUTF8 = Data([0x61, 0xFF, 0xFE, 0x80])
        let embeddedNUL = Data("pre".utf8) + Data([0]) + Data("post".utf8)
        let blob = Data([0x00, 0xFF, 0x01, 0x7F])
        _ = try fixture.insert(key: "composerData:owned", value: composer)
        let invalidRow = try fixture.insert(key: "bubbleId:owned:invalid", value: invalidUTF8)
        let nulRow = try fixture.insert(key: "bubbleId:owned:nul", value: embeddedNUL)
        let blobRow = try fixture.insertBlob(key: "bubbleId:owned:blob", value: blob)
        try fixture.flush()
        let exported = try fixture.exportRows("owned")
        XCTAssertEqual(Data(exported.composer.key.utf8), Data("composerData:owned".utf8))
        XCTAssertEqual(exported.composer.value, Data(composer.utf8))
        XCTAssertEqual(exported.bubbles.map { Data($0.key.utf8) }, [
            Data("bubbleId:owned:invalid".utf8), Data("bubbleId:owned:nul".utf8),
            Data("bubbleId:owned:blob".utf8),
        ])
        XCTAssertEqual(exported.bubbles[0].rowID, invalidRow)
        XCTAssertEqual(exported.bubbles[0].value, invalidUTF8)
        XCTAssertEqual(exported.bubbles[1].rowID, nulRow)
        XCTAssertEqual(exported.bubbles[1].value, embeddedNUL)
        XCTAssertEqual(exported.bubbles[2].rowID, blobRow)
        XCTAssertEqual(exported.bubbles[2].value, blob)
        XCTAssertEqual(exported.composer.storage, .text)
        XCTAssertEqual(exported.bubbles.map(\.storage), [.text, .text, .blob])
        XCTAssertEqual(
            exported.rawPayloadByteCount,
            Int64(composer.utf8.count + invalidUTF8.count + embeddedNUL.count + blob.count)
        )

        let utf16 = try LegacyRowFixture(encoding: "UTF-16le")
        defer { utf16.close() }
        XCTAssertTrue(try utf16.appliedEncoding().hasPrefix("UTF-16"))
        let logicalComposer = #"{"composerId":"utf16"}"#
        let logicalBubble = #"{"type":1,"text":"逻辑-café"}"#
        _ = try utf16.insert(key: "composerData:utf16", value: logicalComposer)
        _ = try utf16.insert(key: "bubbleId:utf16:1", value: logicalBubble)
        try utf16.flush()
        let decoded = try utf16.exportRows("utf16")
        XCTAssertEqual(decoded.composer.value, Data(logicalComposer.utf8))
        XCTAssertEqual(decoded.bubbles.map(\.value), [Data(logicalBubble.utf8)])
        XCTAssertEqual(decoded.rawPayloadByteCount, Int64(logicalComposer.utf8.count + logicalBubble.utf8.count))
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
        XCTAssertTrue(try utf16.stagingNames().isEmpty)
    }

    func testListComposerIDsPagesPastNullTombstonesWithoutChangingSource() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        for id in ["a-deleted", "b-deleted", "d-deleted", "z-deleted"] {
            _ = try fixture.insert(key: "composerData:" + id, value: nil as Data?)
        }
        for id in ["c-live", "e-live"] {
            _ = try fixture.insert(key: "composerData:" + id, value: "{\"composerId\":\"\(id)\"}")
        }
        try fixture.flush()
        let before = try fixture.sourceBytes()
        XCTAssertEqual(try fixture.listComposerIDs(limit: 1).composerIDs, ["c-live"])
        XCTAssertEqual(try fixture.listComposerIDs(after: "c-live", limit: 1).composerIDs, ["e-live"])
        XCTAssertEqual(try fixture.listComposerIDs(after: "e-live", limit: 1).composerIDs, [])
        XCTAssertEqual(try fixture.exportRows("e-live").composerID, "e-live")
        XCTAssertEqual(try fixture.sourceBytes(), before)
    }

    func testNullComposerWithOrphanBubbleIsStillRefusedNotSilentlySkipped() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        _ = try fixture.insert(key: "composerData:orphan", value: nil as Data?)
        _ = try fixture.insert(key: "bubbleId:orphan:1", value: #"{"text":"retained original"}"#)
        try fixture.flush()
        XCTAssertEqual(try fixture.listComposerIDs(limit: 1).composerIDs, ["orphan"])
        assertLegacy(.invalidComposer) { try fixture.exportRows("orphan") }
    }

    func testNullTwinCannotHideDuplicateComposerAmbiguityAtPageBoundary() throws {
        let fixture = try LegacyRowFixture(createDefaultTable: false)
        defer { fixture.close() }
        try fixture.sql("CREATE TABLE cursorDiskKV (key TEXT, value BLOB)")
        _ = try fixture.insert(key: "composerData:twin", value: nil as Data?)
        _ = try fixture.insert(key: "composerData:twin", value: #"{"composerId":"twin"}"#)
        try fixture.flush()
        assertLegacy(.ambiguousScope) { try fixture.listComposerIDs(limit: 1) }
    }

    func testListComposerIDsPreservesExactUTF8OpaquePunctuationAndByteOrderPages_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        let nfc = Data("id".utf8) + Data([0xC3, 0xA9])
        let nfd = Data("id".utf8) + Data([0x65, 0xCC, 0x81])
        XCTAssertNotEqual(nfc, nfd)
        let ids = [Data("Id".utf8), Data("a:b".utf8), Data("id".utf8), Data("id%".utf8),
                   Data("id:".utf8), Data("id_".utf8), nfd, nfc, Data("owned".utf8), Data("sibling".utf8)]
        for id in ids {
            _ = try fixture.insert(
                key: Data("composerData:".utf8) + id,
                value: Data(#"{"composerId":""#.utf8) + id + Data(#""}"#.utf8)
            )
            _ = try fixture.insert(key: Data("bubbleId:".utf8) + id + Data(":1".utf8), value: Data("opaque".utf8))
        }
        try fixture.flush()
        let expected = ids.sorted { $0.lexicographicallyPrecedes($1) }.map { String(data: $0, encoding: .utf8)! }
        let first = try fixture.listComposerIDs(limit: 64)
        XCTAssertEqual(first.composerIDs.map { Data($0.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(first.composerIDs, expected)
        XCTAssertEqual(try fixture.listComposerIDs(after: "b", limit: 64).composerIDs.map { Data($0.utf8) },
                       expected.drop { Data($0.utf8).lexicographicallyPrecedes(Data("b".utf8)) }.map { Data($0.utf8) })
        var collected: [String] = []
        var after: String?
        for _ in 0..<8 {
            let page = try fixture.listComposerIDs(after: after, limit: 3)
            XCTAssertEqual(page.databaseGeneration, first.databaseGeneration)
            XCTAssertEqual(page.walGeneration, first.walGeneration)
            if page.composerIDs.isEmpty { break }
            collected += page.composerIDs
            after = page.composerIDs.last
        }
        XCTAssertEqual(collected.map { Data($0.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(try fixture.listComposerIDs(after: expected.last, limit: 3).composerIDs, [])
        XCTAssertEqual(try fixture.listComposerIDs(limit: 0).composerIDs, [])
        let firstID = try XCTUnwrap(expected.first)
        try fixture.onSharedSnapshot { snapshot, clock in
            let budget = CollectorCursorLegacySource.Budget()
            let hooks = CollectorCursorLegacySource.TestHooks()
            let ids = try CollectorCursorLegacySource.composerIDs(
                snapshot: snapshot, after: nil, limit: 64, budget: budget, testHooks: hooks, clock: clock)
            XCTAssertEqual(ids.map { Data($0.utf8) }, expected.map { Data($0.utf8) })
            let exported = try CollectorCursorLegacySource.readRows(
                snapshot: snapshot, composerID: firstID, budget: budget, testHooks: hooks, clock: clock)
            XCTAssertEqual(Data(exported.composerID.utf8), Data(firstID.utf8))
            XCTAssertEqual(exported.databaseGeneration, first.databaseGeneration)
            XCTAssertEqual(exported.walGeneration, first.walGeneration)
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testListComposerIDsRefusesEmptyNULAndOversizedIdentityAndAfterCursor_repro() throws {
        let empty = try LegacyRowFixture()
        defer { empty.close() }
        _ = try empty.insert(key: "composerData:", value: #"{"composerId":""}"#)
        _ = try empty.insert(key: "composerData:keep", value: #"{"composerId":"keep"}"#)
        try empty.flush()
        assertLegacy(.invalidComposer) { try empty.listComposerIDs(limit: 8) }

        let embeddedNUL = try LegacyRowFixture()
        defer { embeddedNUL.close() }
        let nulID = Data("pre".utf8) + Data([0]) + Data("post".utf8)
        _ = try embeddedNUL.insert(key: Data("composerData:".utf8) + nulID, value: Data("x".utf8))
        try embeddedNUL.flush()
        assertLegacy(.invalidComposer) { try embeddedNUL.listComposerIDs(limit: 8) }

        let oversized = try LegacyRowFixture()
        defer { oversized.close() }
        let long = Data(repeating: 0x61, count: 4097)
        _ = try oversized.insert(key: Data("composerData:".utf8) + long, value: Data("x".utf8))
        try oversized.flush()
        assertLegacy(.invalidComposer) { try oversized.listComposerIDs(limit: 8) }
        assertLegacy(.invalidComposer) { try oversized.listComposerIDs(after: "", limit: 8) }
        assertLegacy(.invalidComposer) {
            try oversized.listComposerIDs(after: String(decoding: Data("a".utf8) + Data([0]) + Data("b".utf8), as: UTF8.self),
                                          limit: 8)
        }
        assertLegacy(.invalidComposer) {
            try oversized.listComposerIDs(after: String(repeating: "a", count: 4097), limit: 8)
        }
        XCTAssertTrue(try empty.stagingNames().isEmpty)
        XCTAssertTrue(try embeddedNUL.stagingNames().isEmpty)
        XCTAssertTrue(try oversized.stagingNames().isEmpty)
    }

    func testListComposerIDsIgnoresValuesBubblesAndOwnershipIndex_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        _ = try fixture.insert(key: "composerData:owned", value: "{not-json")
        _ = try fixture.insert(key: "composerData:other", value: #"{"composerId":"mismatch"}"#)
        _ = try fixture.insert(key: "bubbleId:owned:1", value: #"{"cwd":"/excluded","text":"secret"}"#)
        _ = try fixture.insert(key: "bubbleId:ghost:1", value: #"{"type":1}"#)
        try fixture.sql("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")
        _ = try fixture.insert(into: "ItemTable", key: "composer.composerHeaders",
                               value: #"{"allComposers":[{"composerId":"index-only"}]}"#)
        try fixture.flush()
        let listed = try fixture.listComposerIDs(limit: 8)
        XCTAssertEqual(listed.composerIDs, ["other", "owned"])
        XCTAssertFalse(listed.composerIDs.contains("index-only"))
        XCTAssertFalse(listed.composerIDs.contains(where: { $0.contains("bubble") }))
        XCTAssertTrue(try fixture.stagingNames().isEmpty)

        let view = try LegacyRowFixture(createDefaultTable: false)
        defer { view.close() }
        try view.sql("""
            CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT);
            CREATE VIEW cursorDiskKV AS SELECT key, value FROM kv;
            """)
        _ = try view.insert(into: "kv", key: "composerData:owned", value: #"{"composerId":"owned"}"#)
        try view.flush()
        assertLegacy(.unsupportedSchema) { try view.listComposerIDs(limit: 8) }
        XCTAssertTrue(try view.stagingNames().isEmpty)
    }

    func testListComposerIDsReadsWALOnlyKeysAndRejectsPrefixOnBudgetOrSourceChange_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        try fixture.prepareEmptyWALSchema()
        let checkpointedMain = try Data(contentsOf: fixture.database)
        _ = try fixture.insert(key: "composerData:wal-a", value: #"{"composerId":"wal-a"}"#)
        _ = try fixture.insert(key: "composerData:wal-b", value: #"{"composerId":"wal-b"}"#)
        try fixture.flush()
        let before = try fixture.sourceBytes()
        XCTAssertEqual(before[""], checkpointedMain)
        XCTAssertGreaterThan(try XCTUnwrap(before["-wal"]).count, 32)
        let mainGeneration = try fixture.generation(of: fixture.database)
        let walGeneration = try fixture.generation(of: fixture.wal)
        var opened: [URL] = []
        let listed = try fixture.listComposerIDs(
            limit: 8,
            testHooks: .init(beforeSQLiteOpen: { opened.append($0) })
        )
        XCTAssertEqual(listed.composerIDs, ["wal-a", "wal-b"])
        XCTAssertEqual(listed.databaseGeneration, mainGeneration)
        XCTAssertEqual(listed.walGeneration, walGeneration)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(try XCTUnwrap(opened.first).path.hasPrefix(fixture.staging.path + "/"))
        XCTAssertFalse(try XCTUnwrap(opened.first).path.hasPrefix(fixture.source.path + "/"))
        XCTAssertEqual(try fixture.sourceBytes(), before)
        assertLegacy(.exceededBudget) { try fixture.listComposerIDs(limit: 65) }
        assertLegacy(.exceededBudget) { try fixture.listComposerIDs(limit: -1) }
        assertLegacy(.exceededBudget) { try fixture.listComposerIDs(limit: 2, budget: .init(maximumRows: 1)) }
        assertLegacy(.exceededBudget) { try fixture.listComposerIDs(limit: 8, budget: .init(maximumOutputBytes: 1)) }
        assertLegacy(.exceededBudget) { try fixture.listComposerIDs(limit: 8, budget: .init(maximumSQLiteSteps: 1)) }
        assertLegacy(.sourceChanged) {
            try fixture.listComposerIDs(limit: 8, testHooks: .init(afterRowsRead: {
                _ = try fixture.insert(key: "composerData:late", value: #"{"composerId":"late"}"#)
                try fixture.flush()
            }))
        }
        XCTAssertEqual(try fixture.listComposerIDs(limit: 8).composerIDs, ["late", "wal-a", "wal-b"])
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testListComposerIDsRejectsDuplicateKeyStraddlingPageLimit_repro() throws {
        let fixture = try LegacyRowFixture(createDefaultTable: false)
        defer { fixture.close() }
        try fixture.sql("CREATE TABLE cursorDiskKV (key TEXT, value TEXT);")
        // BINARY order a, b, b, c. LIMIT 2 without a peek returns [a, b];
        // after=b then skips the twin b (same key, two rowids).
        _ = try fixture.insert(key: "composerData:a", value: #"{"composerId":"a"}"#)
        _ = try fixture.insert(key: "composerData:b", value: #"{"composerId":"b-first"}"#)
        _ = try fixture.insert(key: "composerData:b", value: #"{"composerId":"b-second"}"#)
        _ = try fixture.insert(key: "composerData:c", value: #"{"composerId":"c"}"#)
        try fixture.flush()
        assertLegacy(.ambiguousScope) { try fixture.listComposerIDs(limit: 2) }
        assertLegacy(.ambiguousScope) { try fixture.listComposerIDs(after: "a", limit: 1) }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testComposerIDsPagesSameWALLeaseAfterPrivateSHM_repro() throws {
        let fixture = try LegacyRowFixture()
        defer { fixture.close() }
        for id in ["p1", "p2", "p3", "p4"] {
            _ = try fixture.insert(key: "composerData:" + id, value: #"{"composerId":"\#(id)"}"#)
        }
        try fixture.flush()
        try fixture.onSharedSnapshot { snapshot, clock in
            let budget = CollectorCursorLegacySource.Budget()
            let hooks = CollectorCursorLegacySource.TestHooks()
            let first = try CollectorCursorLegacySource.composerIDs(
                snapshot: snapshot, after: nil, limit: 2, budget: budget, testHooks: hooks, clock: clock)
            XCTAssertEqual(first, ["p1", "p2"])
            let second = try CollectorCursorLegacySource.composerIDs(
                snapshot: snapshot, after: first.last, limit: 2, budget: budget, testHooks: hooks, clock: clock)
            XCTAssertEqual(second, ["p3", "p4"])
            XCTAssertEqual(
                try CollectorCursorLegacySource.composerIDs(
                    snapshot: snapshot, after: second.last, limit: 2, budget: budget, testHooks: hooks, clock: clock),
                [])
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }
}

private func assertLegacy(
    _ expected: CollectorCursorLegacySource.LegacyError,
    _ work: () throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
        XCTAssertEqual(error as? CollectorCursorLegacySource.LegacyError, expected, file: file, line: line)
    }
}

private final class LegacyRowFixture {
    let base: URL
    let source: URL
    let staging: URL
    private var writer: OpaquePointer?

    var database: URL { source.appendingPathComponent("state.vscdb") }
    var wal: URL { URL(fileURLWithPath: database.path + "-wal") }
    var shm: URL { URL(fileURLWithPath: database.path + "-shm") }
    var journal: URL { URL(fileURLWithPath: database.path + "-journal") }

    init(encoding: String = "UTF-8", createDefaultTable: Bool = true) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cursor-legacy-rows-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        source = base.appendingPathComponent("source")
        staging = base.appendingPathComponent("private-staging")
        for directory in [source, staging] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw POSIXError(.EIO) }
        writer = handle
        switch encoding {
        case "UTF-8":
            break
        case "UTF-16le":
            try sql("PRAGMA encoding='UTF-16le';")
        default:
            throw POSIXError(.EINVAL)
        }
        try sql("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        if createDefaultTable {
            try sql("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);")
        }
    }

    func prepareEmptyWALSchema() throws {
        try sql("PRAGMA user_version=7; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    @discardableResult
    func insert(key: String, value: String?) throws -> Int64 {
        try insert(key: Data(key.utf8), value: value.map { Data($0.utf8) })
    }

    @discardableResult
    func insert(key: String, value: Data?) throws -> Int64 {
        try insert(key: Data(key.utf8), value: value)
    }

    @discardableResult
    func insert(into table: String, key: String, value: String) throws -> Int64 {
        try insert(into: table, key: Data(key.utf8), value: Data(value.utf8))
    }

    @discardableResult
    func insert(key: Data, value: Data?) throws -> Int64 {
        try insert(into: "cursorDiskKV", key: key, value: value)
    }

    @discardableResult
    func insert(into table: String, key: Data, value: Data?) throws -> Int64 {
        guard let writer else { throw POSIXError(.EIO) }
        let sql: String
        switch table {
        case "cursorDiskKV": sql = "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)"
        case "kv": sql = "INSERT INTO kv(key, value) VALUES (?, ?)"
        case "ItemTable": sql = "INSERT INTO ItemTable(key, value) VALUES (?, ?)"
        default: throw POSIXError(.EINVAL)
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try bindText(statement, 1, key, transient)
        if let value {
            try bindText(statement, 2, value, transient)
        } else {
            guard sqlite3_bind_null(statement, 2) == SQLITE_OK else { throw POSIXError(.EIO) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw POSIXError(.EIO) }
        return sqlite3_last_insert_rowid(writer)
    }

    private func bindText(
        _ statement: OpaquePointer, _ index: Int32, _ bytes: Data, _ destructor: sqlite3_destructor_type
    ) throws {
        try bytes.withUnsafeBytes { buffer in
            let pointer = buffer.bindMemory(to: Int8.self).baseAddress
            guard sqlite3_bind_text(statement, index, pointer, Int32(bytes.count), destructor) == SQLITE_OK else {
                throw POSIXError(.EIO)
            }
        }
    }

    func exportRows(
        utf8 composerID: Data,
        budget: CollectorCursorLegacySource.Budget = .init(),
        testHooks: CollectorCursorLegacySource.TestHooks = .init()
    ) throws -> CollectorCursorLegacySource.ExportedRows {
        try exportRows(String(decoding: composerID, as: UTF8.self), budget: budget, testHooks: testHooks)
    }

    func insertOwnedAndSibling(
        composer: String = #"{"composerId":"owned"}"#,
        firstBubble: String = #"{"type":2,"text":"later-key-first-rowid"}"#,
        malformed: String = "{not-json",
        lateBubble: String = #"{"type":1,"text":"after-null"}"#
    ) throws -> (
        composer: CollectorCursorLegacySource.Row,
        bubbles: [CollectorCursorLegacySource.Row],
        payloadBytes: Int64
    ) {
        let composerID = try insert(key: "composerData:owned", value: composer)
        _ = try insert(key: "bubbleId:sibling:early", value: #"{"type":1,"text":"SIBLING-EARLY"}"#)
        let first = try insert(key: "bubbleId:owned:z", value: firstBubble)
        _ = try insert(key: "composerData:sibling", value: #"{"composerId":"sibling"}"#)
        let malformedID = try insert(key: "bubbleId:owned:malformed", value: malformed)
        let nullID = try insert(key: "bubbleId:owned:null", value: Optional<String>.none)
        _ = try insert(key: "bubbleId:sibling:late", value: #"{"type":2,"text":"SIBLING-LATE"}"#)
        let late = try insert(key: "bubbleId:owned:late", value: lateBubble)
        try flush()
        let bubbles = [
            CollectorCursorLegacySource.Row(rowID: first, key: "bubbleId:owned:z", value: Data(firstBubble.utf8)),
            CollectorCursorLegacySource.Row(
                rowID: malformedID, key: "bubbleId:owned:malformed", value: Data(malformed.utf8)
            ),
            CollectorCursorLegacySource.Row(rowID: nullID, key: "bubbleId:owned:null", value: nil),
            CollectorCursorLegacySource.Row(rowID: late, key: "bubbleId:owned:late", value: Data(lateBubble.utf8)),
        ]
        let payload = Int64(composer.utf8.count + firstBubble.utf8.count + malformed.utf8.count + lateBubble.utf8.count)
        return (
            CollectorCursorLegacySource.Row(rowID: composerID, key: "composerData:owned", value: Data(composer.utf8)),
            bubbles,
            payload
        )
    }

    func exportRows(
        _ composerID: String,
        budget: CollectorCursorLegacySource.Budget = .init(),
        testHooks: CollectorCursorLegacySource.TestHooks = .init()
    ) throws -> CollectorCursorLegacySource.ExportedRows {
        try CollectorCursorLegacySource.exportRows(
            globalStorageRoot: source, composerID: composerID, stagingParent: staging,
            budget: budget, testHooks: testHooks
        )
    }

    func listComposerIDs(
        after: String? = nil, limit: Int,
        budget: CollectorCursorLegacySource.Budget = .init(),
        testHooks: CollectorCursorLegacySource.TestHooks = .init()
    ) throws -> CollectorCursorLegacySource.DiscoveredComposers {
        try CollectorCursorLegacySource.listComposerIDs(
            globalStorageRoot: source, stagingParent: staging, after: after, limit: limit,
            budget: budget, testHooks: testHooks
        )
    }

    func onSharedSnapshot<T>(
        budget: CollectorCursorLegacySource.Budget = .init(),
        testHooks: CollectorCursorLegacySource.TestHooks = .init(),
        _ body: (CollectorSQLiteSnapshotLease.Snapshot, LegacyReadClock) throws -> T
    ) throws -> T {
        let clock = try LegacyReadClock(budget)
        do {
            return try CollectorSQLiteSnapshotLease.withSnapshot(
                root: source, databaseName: "state.vscdb", stagingParent: staging,
                budget: budget.snapshot, testHooks: testHooks.snapshot
            ) { snapshot in
                try body(snapshot, clock)
            }
        } catch let error as CollectorSQLiteSnapshotError {
            switch error {
            case .exceededBudget: throw CollectorCursorLegacySource.LegacyError.exceededBudget
            case .sourceChanged, .unsafePath: throw CollectorCursorLegacySource.LegacyError.sourceChanged
            case .unavailable: throw CollectorCursorLegacySource.LegacyError.unavailable
            }
        }
    }

    func sql(_ value: String) throws {
        guard let writer else { throw POSIXError(.EIO) }
        var errmsg: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(writer, value, nil, nil, &errmsg)
        let message = errmsg.map { String(cString: $0) }
        sqlite3_free(errmsg)
        guard status == SQLITE_OK else {
            throw NSError(
                domain: "LegacyRowFixture.sql", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message ?? "sqlite3_exec"]
            )
        }
    }

    func flush() throws {
        guard let writer, sqlite3_db_cacheflush(writer) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    func appliedEncoding() throws -> String {
        guard let writer else { throw POSIXError(.EIO) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, "PRAGMA encoding", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw POSIXError(.EIO) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw POSIXError(.EIO)
        }
        return String(cString: text)
    }

    func disablePersistentWAL() throws {
        guard let writer else { throw POSIXError(.EIO) }
        var persist: Int32 = 0
        guard sqlite3_file_control(writer, "main", SQLITE_FCNTL_PERSIST_WAL, &persist) == SQLITE_OK else {
            throw POSIXError(.EIO)
        }
    }

    func stopWriter() {
        if let writer {
            XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
            self.writer = nil
        }
    }

    @discardableResult
    func insertBlob(key: String, value: Data) throws -> Int64 {
        guard let writer else { throw POSIXError(.EIO) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            writer, "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)", -1, &statement, nil
        ) == SQLITE_OK, let statement else { throw POSIXError(.EIO) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try bindText(statement, 1, Data(key.utf8), transient)
        try value.withUnsafeBytes { buffer in
            let pointer = buffer.baseAddress
            guard sqlite3_bind_blob(statement, 2, pointer, Int32(value.count), transient) == SQLITE_OK else {
                throw POSIXError(.EIO)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw POSIXError(.EIO) }
        return sqlite3_last_insert_rowid(writer)
    }

    func rebindSourceRoot() throws {
        stopWriter()
        let moved = base.appendingPathComponent("moved-source")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
    }

    func sourceNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
    }

    func sourceBytes() throws -> [String: Data] {
        var bytes: [String: Data] = ["": try Data(contentsOf: database)]
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                bytes[suffix] = try Data(contentsOf: url)
            }
        }
        return bytes
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

    func stagingNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: staging.path)
    }

    func close() {
        stopWriter()
        try? FileManager.default.removeItem(at: base)
    }
}

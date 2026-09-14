import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EngramCollectorCore

/// Frozen cwd only. Not transport, upload, or message parse.
final class CollectorCursorLegacyOwnershipTests: XCTestCase {
    func testCapturedBodyPersistsRowsOwnershipAndGenerationAfterSourceRemoval_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/durable"
        try fixture.insertComposer("owned", json: #"{"composerId":"owned","conversation":[{"type":1,"text":"durable"}]}"#)
        try fixture.addWorkspace("ws-a", folderURI: folder, index: fixture.indexJSON(ids: ["owned"]))
        try fixture.flushAll()
        let capture = try fixture.capture("owned")
        let session = try capture.archiveSession()
        let archive = fixture.base.appendingPathComponent("captured-session.json")
        try session.encodeCanonical().write(to: archive, options: .atomic)
        fixture.closeSources()
        try FileManager.default.removeItem(at: fixture.userRoot)
        let restored = try ArchiveCursorLegacySession.decodeCanonical(Data(contentsOf: archive))
        XCTAssertEqual(restored, session)
        XCTAssertEqual(restored.logicalDatabaseLocator, fixture.globalDatabase.path)
        XCTAssertEqual(restored.logicalLocator, fixture.globalDatabase.path + "?composer=owned")
        XCTAssertEqual(restored.cwd, Self.cwd(folder))
        XCTAssertEqual(restored.databaseGeneration, capture.rows.databaseGeneration)
        XCTAssertEqual(restored.walGeneration, capture.rows.walGeneration)
        XCTAssertEqual(restored.composer, capture.rows.composer)
        XCTAssertEqual(restored.bubbles, capture.rows.bubbles)
        XCTAssertEqual(restored.rawPayloadByteCount, capture.rows.rawPayloadByteCount)
        XCTAssertEqual(restored.composer.storage, .text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.userRoot.path))
    }

    func testUniqueWorkspaceLinkFreezesSingleCwd_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/unique"
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-a", folderURI: folder, index: fixture.indexJSON(ids: ["owned"]))
        try fixture.flushAll()

        let captured = try fixture.capture("owned")
        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertEqual(captured.rows.composerID, "owned")
        XCTAssertEqual(captured.rows.composer.value, Data(#"{"composerId":"owned"}"#.utf8))
        XCTAssertEqual(captured.rows.rawPayloadByteCount, Int64(#"{"composerId":"owned"}"#.utf8.count))
        XCTAssertGreaterThan(captured.ownershipPayloadByteCount, 0)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testHeadersOnlyLinkWithAbsentLocalIndexFreezesCwd_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/headers-only"
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-a", folderURI: folder, createDatabase: false)
        let headers = fixture.headersJSON([("owned", "ws-a")])
        try fixture.setHeaders(headers)
        try fixture.flushAll()

        let captured = try fixture.capture("owned")
        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertEqual(captured.rows.composer.value, Data(#"{"composerId":"owned"}"#.utf8))
        XCTAssertGreaterThanOrEqual(captured.ownershipPayloadByteCount, Int64(headers.count))
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testIdenticalWorkspaceAndHeaderUnionAccepted_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/union-same"
        try fixture.insertComposer("owned")
        let index = fixture.indexJSON(ids: ["owned"])
        try fixture.addWorkspace("ws-a", folderURI: folder, index: index)
        try fixture.setHeaders(fixture.headersJSON([("owned", "ws-a")]))
        try fixture.flushAll()

        let captured = try fixture.capture("owned")
        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertEqual(captured.rows.rawPayloadByteCount, Int64(#"{"composerId":"owned"}"#.utf8.count))
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testConflictingUnionOrNoEvidenceLeavesCwdEmpty_repro() throws {
        let conflict = try OwnershipFixture()
        defer { conflict.close() }
        try conflict.insertComposer("owned")
        try conflict.addWorkspace(
            "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/conflict-a",
            index: conflict.indexJSON(ids: ["owned"])
        )
        try conflict.addWorkspace(
            "ws-b", folderURI: "file:///tmp/engram-legacy-ownership/conflict-b",
            index: conflict.indexJSON(ids: ["owned"])
        )
        try conflict.flushAll()
        let contested = try conflict.capture("owned")
        XCTAssertEqual(contested.cwd, "")
        XCTAssertEqual(contested.rows.composerID, "owned")
        XCTAssertEqual(contested.rows.rawPayloadByteCount, Int64(#"{"composerId":"owned"}"#.utf8.count))

        let headersConflict = try OwnershipFixture()
        defer { headersConflict.close() }
        try headersConflict.insertComposer("owned")
        try headersConflict.addWorkspace(
            "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/header-a",
            index: headersConflict.indexJSON(ids: ["owned"])
        )
        try headersConflict.addWorkspace(
            "ws-b", folderURI: "file:///tmp/engram-legacy-ownership/header-b", createDatabase: false
        )
        try headersConflict.setHeaders(headersConflict.headersJSON([("owned", "ws-b")]))
        try headersConflict.flushAll()
        XCTAssertEqual(try headersConflict.capture("owned").cwd, "")

        let empty = try OwnershipFixture()
        defer { empty.close() }
        try empty.insertComposer("owned")
        try empty.setHeaders(empty.headersJSON([]))
        try empty.flushAll()
        let none = try empty.capture("owned")
        XCTAssertEqual(none.cwd, "")
        XCTAssertEqual(none.rows.composer.value, Data(#"{"composerId":"owned"}"#.utf8))
        XCTAssertTrue(try conflict.stagingNames().isEmpty)
        XCTAssertTrue(try headersConflict.stagingNames().isEmpty)
        XCTAssertTrue(try empty.stagingNames().isEmpty)
    }

    func testFileAndFolderSelectionsNeverBecomeOwnership_repro() throws {
        let selectionsOnly = try OwnershipFixture()
        defer { selectionsOnly.close() }
        let selected = "/tmp/engram-legacy-ownership/from-selection"
        let composer = """
            {"composerId":"owned","context":{"fileSelections":[{"uri":{"fsPath":"\(selected)"}}],\
            "folderSelections":[{"uri":{"fsPath":"/tmp/engram-legacy-ownership/from-folder"}}]}}
            """
        try selectionsOnly.insertComposer("owned", json: composer)
        try selectionsOnly.setHeaders(selectionsOnly.headersJSON([]))
        try selectionsOnly.flushAll()
        let ignored = try selectionsOnly.capture("owned")
        XCTAssertEqual(ignored.cwd, "")
        XCTAssertNotEqual(ignored.cwd, selected)
        XCTAssertEqual(ignored.rows.rawPayloadByteCount, Int64(composer.utf8.count))

        let workspaceWins = try OwnershipFixture()
        defer { workspaceWins.close() }
        let folder = "file:///tmp/engram-legacy-ownership/from-workspace"
        try workspaceWins.insertComposer("owned", json: composer)
        try workspaceWins.addWorkspace(
            "ws-a", folderURI: folder, index: workspaceWins.indexJSON(ids: ["owned"])
        )
        try workspaceWins.flushAll()
        let captured = try workspaceWins.capture("owned")
        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertNotEqual(captured.cwd, selected)
        XCTAssertTrue(try selectionsOnly.stagingNames().isEmpty)
        XCTAssertTrue(try workspaceWins.stagingNames().isEmpty)
    }

    func testMultiRootConfigurationNullAndNonlocalURIAreRejected_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("owned")
        try fixture.addWorkspace(
            "ws-null", folderURI: "file:///tmp/engram-legacy-ownership/configured-null",
            configurationJSON: "null", index: fixture.indexJSON(ids: ["owned"])
        )
        try fixture.addWorkspace(
            "ws-object", folderURI: "file:///tmp/engram-legacy-ownership/configured-object",
            configurationJSON: "{}", index: fixture.indexJSON(ids: ["owned"])
        )
        try fixture.addWorkspace(
            "ws-http", folderURI: "https://example.com/engram-legacy-ownership",
            index: fixture.indexJSON(ids: ["owned"])
        )
        try fixture.addWorkspace(
            "ws-remote", folderURI: "file://fileserver.example/share",
            index: fixture.indexJSON(ids: ["owned"])
        )
        try fixture.flushAll()
        XCTAssertEqual(try fixture.capture("owned").cwd, "")

        let localhost = try OwnershipFixture()
        defer { localhost.close() }
        let folder = "file://localhost/tmp/engram-legacy-ownership/localhost"
        try localhost.insertComposer("owned")
        try localhost.addWorkspace("ws-local", folderURI: folder, index: localhost.indexJSON(ids: ["owned"]))
        try localhost.flushAll()
        XCTAssertEqual(try localhost.capture("owned").cwd, Self.cwd(folder))
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
        XCTAssertTrue(try localhost.stagingNames().isEmpty)
    }

    func testLiteralByteComposerIDsKeepDistinctOwnership_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let nfc = Data("id".utf8) + Data([0xC3, 0xA9])
        let nfd = Data("id".utf8) + Data([0x65, 0xCC, 0x81])
        XCTAssertNotEqual(nfc, nfd)
        let nfcFolder = "file:///tmp/engram-legacy-ownership/nfc"
        let nfdFolder = "file:///tmp/engram-legacy-ownership/nfd"
        try fixture.insertComposer(utf8: nfc)
        try fixture.insertComposer(utf8: nfd)
        try fixture.addWorkspace("ws-nfc", folderURI: nfcFolder, index: fixture.indexJSON(ids: [nfc]))
        try fixture.addWorkspace("ws-nfd", folderURI: nfdFolder, index: fixture.indexJSON(ids: [nfd]))
        try fixture.flushAll()

        let nfcCapture = try fixture.capture(utf8: nfc)
        let nfdCapture = try fixture.capture(utf8: nfd)
        XCTAssertEqual(Data(nfcCapture.rows.composerID.utf8), nfc)
        XCTAssertEqual(Data(nfdCapture.rows.composerID.utf8), nfd)
        XCTAssertEqual(nfcCapture.cwd, Self.cwd(nfcFolder))
        XCTAssertEqual(nfdCapture.cwd, Self.cwd(nfdFolder))
        XCTAssertNotEqual(nfcCapture.cwd, nfdCapture.cwd)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testHeldWriterWALOnlyOwnershipExportsWithoutTouchingSourceBytes_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/wal-only"
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-a", folderURI: folder, createDatabase: true)
        try fixture.prepareEmptyWALSchema(workspace: "ws-a")
        let checkpointedMain = try Data(contentsOf: fixture.workspaceDatabase("ws-a"))
        let index = fixture.indexJSON(ids: ["owned"])
        try fixture.setWorkspaceIndex("ws-a", index)
        try fixture.flushAll()

        let beforeGlobal = try fixture.globalBytes()
        let beforeWorkspace = try fixture.workspaceBytes("ws-a")
        XCTAssertEqual(beforeWorkspace[""], checkpointedMain)
        XCTAssertGreaterThan(try XCTUnwrap(beforeWorkspace["-wal"]).count, 32)
        let globalMain = try fixture.generation(of: fixture.globalDatabase)
        let globalWAL = try fixture.generation(of: fixture.globalWAL)
        let workspaceMain = try fixture.generation(of: fixture.workspaceDatabase("ws-a"))
        let workspaceWAL = try fixture.generation(of: fixture.workspaceWAL("ws-a"))
        var opened: [URL] = []
        var readWorkspaces: [URL] = []
        let captured = try fixture.capture(
            "owned",
            testHooks: .init(
                beforeSQLiteOpen: { opened.append($0) },
                afterWorkspaceRead: { readWorkspaces.append($0) }
            )
        )

        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertEqual(captured.rows.composerID, "owned")
        XCTAssertEqual(captured.rows.rawPayloadByteCount, Int64(#"{"composerId":"owned"}"#.utf8.count))
        XCTAssertFalse(opened.isEmpty)
        XCTAssertTrue(opened.allSatisfy { $0.path.hasPrefix(fixture.staging.path + "/") })
        XCTAssertTrue(opened.allSatisfy { !$0.path.hasPrefix(fixture.globalStorage.path + "/") })
        XCTAssertFalse(readWorkspaces.isEmpty)
        XCTAssertEqual(try fixture.globalBytes(), beforeGlobal)
        XCTAssertEqual(try fixture.workspaceBytes("ws-a"), beforeWorkspace)
        XCTAssertEqual(try fixture.generation(of: fixture.globalDatabase), globalMain)
        XCTAssertEqual(try fixture.generation(of: fixture.globalWAL), globalWAL)
        XCTAssertEqual(try fixture.generation(of: fixture.workspaceDatabase("ws-a")), workspaceMain)
        XCTAssertEqual(try fixture.generation(of: fixture.workspaceWAL("ws-a")), workspaceWAL)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testBeforeFinalValidationSourceMutationsAndNewWorkspaceAreRejected_repro() throws {
        for kind in ["workspace-db", "workspace-json", "global-wal", "new-workspace"] {
            let fixture = try OwnershipFixture()
            defer { fixture.close() }
            let folder = "file:///tmp/engram-legacy-ownership/fence-\(kind)"
            try fixture.insertComposer("owned")
            try fixture.addWorkspace("ws-a", folderURI: folder, index: fixture.indexJSON(ids: ["owned"]))
            try fixture.flushAll()
            assertLegacy(.sourceChanged) {
                try fixture.capture("owned", testHooks: .init(beforeFinalValidation: {
                    switch kind {
                    case "workspace-db":
                        try fixture.setWorkspaceIndex("ws-a", fixture.indexJSON(ids: ["owned", "late"]))
                        try fixture.flushAll()
                    case "workspace-json":
                        try fixture.writeWorkspaceJSON(
                            "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/fence-changed"
                        )
                    case "global-wal":
                        try fixture.insertComposer("late")
                        try fixture.flushAll()
                    default:
                        try fixture.addWorkspace(
                            "ws-new",
                            folderURI: "file:///tmp/engram-legacy-ownership/fence-new",
                            createDatabase: false
                        )
                    }
                }))
            }
            XCTAssertTrue(try fixture.stagingNames().isEmpty)
        }
    }

    func testInvalidAndSymlinkInputsCannotManufactureUniqueOwnership_repro() throws {
        let hidden = try OwnershipFixture()
        defer { hidden.close() }
        try hidden.insertComposer("owned")
        try hidden.addWorkspace(
            ".hidden", folderURI: "file:///tmp/engram-legacy-ownership/hidden",
            index: hidden.indexJSON(ids: ["owned"])
        )
        try hidden.flushAll()
        XCTAssertEqual(try hidden.capture("owned").cwd, "")

        let linkedDir = try OwnershipFixture()
        defer { linkedDir.close() }
        try linkedDir.insertComposer("owned")
        let real = linkedDir.base.appendingPathComponent("real-ws")
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        try Data(#"{"folder":"file:///tmp/engram-legacy-ownership/symlink-dir"}"#.utf8)
            .write(to: real.appendingPathComponent("workspace.json"))
        try linkedDir.openWorkspaceDatabase(at: real, id: "real-ws")
        try linkedDir.setWorkspaceIndex("real-ws", linkedDir.indexJSON(ids: ["owned"]))
        try FileManager.default.createSymbolicLink(
            at: linkedDir.workspaceStorage.appendingPathComponent("ws-alias"), withDestinationURL: real
        )
        try linkedDir.flushAll()
        XCTAssertEqual(try linkedDir.capture("owned").cwd, "")

        let linkedJSON = try OwnershipFixture()
        defer { linkedJSON.close() }
        try linkedJSON.insertComposer("owned")
        let stolen = linkedJSON.base.appendingPathComponent("stolen.json")
        try Data(#"{"folder":"file:///tmp/engram-legacy-ownership/stolen"}"#.utf8).write(to: stolen)
        let jsonWorkspace = linkedJSON.workspaceStorage.appendingPathComponent("ws-link")
        try FileManager.default.createDirectory(
            at: jsonWorkspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: jsonWorkspace.appendingPathComponent("workspace.json"), withDestinationURL: stolen
        )
        try linkedJSON.flushAll()
        XCTAssertEqual(try linkedJSON.capture("owned").cwd, "")

        let wrongName = try OwnershipFixture()
        defer { wrongName.close() }
        try wrongName.insertComposer("owned")
        try wrongName.addWorkspace(
            "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/wrong-root",
            index: wrongName.indexJSON(ids: ["owned"])
        )
        try wrongName.installAlternateGlobalStorage("wrongName")
        try wrongName.flushAll()
        XCTAssertEqual(try wrongName.capture("owned", root: wrongName.userRoot.appendingPathComponent("wrongName")).cwd, "")
        XCTAssertTrue(try hidden.stagingNames().isEmpty)
        XCTAssertTrue(try linkedDir.stagingNames().isEmpty)
        XCTAssertTrue(try linkedJSON.stagingNames().isEmpty)
        XCTAssertTrue(try wrongName.stagingNames().isEmpty)
    }

    func testRowRawPayloadExcludesOwnershipBytes_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let composer = #"{"composerId":"owned"}"#
        let folder = "file:///tmp/engram-legacy-ownership/payload-split"
        let index = fixture.paddedIndex(id: "owned", pad: 2_048)
        let headers = fixture.headersJSON([("owned", "ws-a")])
        try fixture.insertComposer("owned", json: composer)
        try fixture.addWorkspace("ws-a", folderURI: folder, index: index)
        try fixture.setHeaders(headers)
        try fixture.flushAll()

        let captured = try fixture.capture("owned")
        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertEqual(captured.rows.rawPayloadByteCount, Int64(composer.utf8.count))
        let metadata = try Data(contentsOf: fixture.workspaceStorage.appendingPathComponent("ws-a/workspace.json"))
        XCTAssertEqual(captured.ownershipPayloadByteCount, Int64(index.count + headers.count + metadata.count))
        XCTAssertGreaterThan(captured.ownershipPayloadByteCount, captured.rows.rawPayloadByteCount)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testOwnershipByteWorkspaceAndVMBudgetsRejectPrefix_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("owned")
        try fixture.insertComposer("other")
        let index = fixture.paddedIndex(id: "owned", pad: 1_024)
        try fixture.addWorkspace(
            "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/budget-a", index: index
        )
        try fixture.addWorkspace(
            "ws-b", folderURI: "file:///tmp/engram-legacy-ownership/budget-b",
            index: fixture.indexJSON(ids: ["other"])
        )
        try fixture.flushAll()
        let full = try fixture.capture("owned")
        XCTAssertEqual(full.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/budget-a"))
        XCTAssertGreaterThan(full.ownershipPayloadByteCount, 1)

        assertLegacy(.exceededBudget) {
            try fixture.capture("owned", budget: .init(maximumWorkspaces: 0))
        }
        assertLegacy(.exceededBudget) {
            try fixture.capture("owned", budget: .init(maximumWorkspaces: 1))
        }
        assertLegacy(.exceededBudget) {
            try fixture.capture("owned", budget: .init(maximumOwnershipBytes: 0))
        }
        assertLegacy(.exceededBudget) {
            try fixture.capture("owned", budget: .init(maximumOwnershipBytes: full.ownershipPayloadByteCount - 1))
        }
        assertLegacy(.exceededBudget) {
            try fixture.capture("owned", budget: .init(maximumSQLiteSteps: 1))
        }
        let exact = try fixture.capture("owned", budget: .init(maximumOwnershipBytes: full.ownershipPayloadByteCount))
        XCTAssertEqual(exact.cwd, full.cwd)
        XCTAssertEqual(exact.ownershipPayloadByteCount, full.ownershipPayloadByteCount)
        let again = try fixture.capture("owned")
        XCTAssertEqual(again.cwd, full.cwd)
        XCTAssertEqual(again.rows.rawPayloadByteCount, full.rows.rawPayloadByteCount)
        XCTAssertEqual(again.ownershipPayloadByteCount, full.ownershipPayloadByteCount)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testMalformedOrUnreadableEligibleWorkspaceIndexWithholdsRemainingCandidate_repro() throws {
        let malformed = try OwnershipFixture()
        defer { malformed.close() }
        let goodFolder = "file:///tmp/engram-legacy-ownership/good-malformed"
        try malformed.insertComposer("owned")
        try malformed.addWorkspace(
            "ws-good", folderURI: goodFolder, index: malformed.indexJSON(ids: ["owned"])
        )
        try malformed.addWorkspace(
            "ws-bad", folderURI: "file:///tmp/engram-legacy-ownership/bad-malformed",
            index: Data("{not-json".utf8)
        )
        try malformed.flushAll()
        try assertWithheld(forbiddenCwd: Self.cwd(goodFolder)) {
            try malformed.capture("owned")
        }

        let unreadable = try OwnershipFixture()
        defer { unreadable.close() }
        let readableFolder = "file:///tmp/engram-legacy-ownership/good-unreadable"
        try unreadable.insertComposer("owned")
        try unreadable.addWorkspace(
            "ws-good", folderURI: readableFolder, index: unreadable.indexJSON(ids: ["owned"])
        )
        try unreadable.addWorkspace(
            "ws-bad", folderURI: "file:///tmp/engram-legacy-ownership/bad-unreadable", createDatabase: false
        )
        try Data("not-a-sqlite-database".utf8).write(to: unreadable.workspaceDatabase("ws-bad"))
        try unreadable.flushAll()
        try assertWithheld(forbiddenCwd: Self.cwd(readableFolder)) {
            try unreadable.capture("owned")
        }
        XCTAssertTrue(try malformed.stagingNames().isEmpty)
        XCTAssertTrue(try unreadable.stagingNames().isEmpty)
    }

    func testMalformedGlobalHeadersWithValidLocalCandidateWithholds_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/headers-malformed"
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-a", folderURI: folder, index: fixture.indexJSON(ids: ["owned"]))
        try fixture.setHeaders(Data("{not-json".utf8))
        try fixture.flushAll()
        try assertWithheld(forbiddenCwd: Self.cwd(folder)) {
            try fixture.capture("owned")
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testMissingGlobalItemTableStillFreezesValidLocalOwnership_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/no-itemtable"
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-a", folderURI: folder, index: fixture.indexJSON(ids: ["owned"]))
        try fixture.dropGlobalItemTable()
        try fixture.flushAll()
        let captured = try fixture.capture("owned")
        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertEqual(captured.rows.composerID, "owned")
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testMalformedWorkspaceJSONAlongsideValidCandidateWithholds_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/json-malformed-good"
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-good", folderURI: folder, index: fixture.indexJSON(ids: ["owned"]))
        try fixture.addWorkspace(
            "ws-bad", folderURI: "file:///tmp/engram-legacy-ownership/json-malformed-bad", createDatabase: false
        )
        try fixture.writeRawWorkspaceJSON("ws-bad", Data("{not-json".utf8))
        try fixture.flushAll()
        try assertWithheld(forbiddenCwd: Self.cwd(folder)) {
            try fixture.capture("owned")
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testHeadersOnlyDatabaseAppearanceAndOwnershipInputDeletionAreRejected_repro() throws {
        for kind in ["appear-db", "delete-json", "delete-db"] {
            let fixture = try OwnershipFixture()
            defer { fixture.close() }
            try fixture.insertComposer("owned")
            if kind == "appear-db" {
                try fixture.addWorkspace(
                    "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/appear-db", createDatabase: false
                )
                try fixture.setHeaders(fixture.headersJSON([("owned", "ws-a")]))
            } else {
                try fixture.addWorkspace(
                    "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/\(kind)",
                    index: fixture.indexJSON(ids: ["owned"])
                )
            }
            try fixture.flushAll()
            assertLegacy(.sourceChanged) {
                try fixture.capture("owned", testHooks: .init(beforeFinalValidation: {
                    switch kind {
                    case "appear-db":
                        try Data("appeared-workspace-db".utf8).write(to: fixture.workspaceDatabase("ws-a"))
                    case "delete-json":
                        try fixture.removeWorkspaceJSON("ws-a")
                    default:
                        try fixture.closeWorkspaceWriter("ws-a")
                        try FileManager.default.removeItem(at: fixture.workspaceDatabase("ws-a"))
                    }
                }))
            }
            XCTAssertTrue(try fixture.stagingNames().isEmpty)
        }
    }

    func testEarlierWorkspaceIndexMutationInAfterWorkspaceReadIsRejected_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("owned")
        try fixture.insertComposer("other")
        try fixture.addWorkspace(
            "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/after-read-a",
            index: fixture.indexJSON(ids: ["owned"])
        )
        try fixture.addWorkspace(
            "ws-b", folderURI: "file:///tmp/engram-legacy-ownership/after-read-b",
            index: fixture.indexJSON(ids: ["other"])
        )
        try fixture.flushAll()
        var mutated = false
        assertLegacy(.sourceChanged) {
            try fixture.capture("owned", testHooks: .init(afterWorkspaceRead: { _ in
                if mutated { return }
                mutated = true
                try fixture.setWorkspaceIndex("ws-a", fixture.indexJSON(ids: ["owned", "late"]))
                try fixture.flushAll()
            }))
        }
        XCTAssertTrue(mutated)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testWorkspaceStorageMissingOrSymlinkCannotInventCwdAndAppearingRootRejects_repro() throws {
        let missing = try OwnershipFixture()
        defer { missing.close() }
        try missing.insertComposer("owned")
        try missing.flushAll()
        try FileManager.default.removeItem(at: missing.workspaceStorage)
        XCTAssertEqual(try missing.capture("owned").cwd, "")
        XCTAssertTrue(try missing.stagingNames().isEmpty)

        let linked = try OwnershipFixture()
        defer { linked.close() }
        try linked.insertComposer("owned")
        try linked.addWorkspace(
            "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/symlink-root",
            index: linked.indexJSON(ids: ["owned"])
        )
        try linked.flushAll()
        try linked.closeWorkspaceWriter("ws-a")
        let foreign = linked.base.appendingPathComponent("foreign-workspaceStorage")
        try FileManager.default.moveItem(at: linked.workspaceStorage, to: foreign)
        try FileManager.default.createSymbolicLink(at: linked.workspaceStorage, withDestinationURL: foreign)
        XCTAssertEqual(try linked.capture("owned").cwd, "")
        XCTAssertTrue(try linked.stagingNames().isEmpty)

        let appear = try OwnershipFixture()
        defer { appear.close() }
        try appear.insertComposer("owned")
        try appear.flushAll()
        try FileManager.default.removeItem(at: appear.workspaceStorage)
        assertLegacy(.sourceChanged) {
            try appear.capture("owned", testHooks: .init(beforeFinalValidation: {
                try FileManager.default.createDirectory(
                    at: appear.workspaceStorage, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try appear.addWorkspace(
                    "ws-a", folderURI: "file:///tmp/engram-legacy-ownership/appeared-root",
                    index: appear.indexJSON(ids: ["owned"])
                )
            }))
        }
        XCTAssertTrue(try appear.stagingNames().isEmpty)
    }

    func testRowAndHeaderReadsShareOneGlobalPrivateSnapshot_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        let folder = "file:///tmp/engram-legacy-ownership/shared-global"
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-a", folderURI: folder, index: fixture.indexJSON(ids: ["owned"]))
        try fixture.setHeaders(fixture.headersJSON([("owned", "ws-a")]))
        try fixture.flushAll()
        var staged: [(name: String, cloned: Bool)] = []
        var opened: [URL] = []
        let captured = try fixture.capture(
            "owned",
            testHooks: .init(
                rows: .init(snapshot: .init(didStageSourceFile: { name, cloned, _ in
                    staged.append((name, cloned))
                })),
                beforeSQLiteOpen: { opened.append($0) }
            )
        )
        XCTAssertEqual(captured.cwd, Self.cwd(folder))
        XCTAssertEqual(staged.filter { $0.name == "state.vscdb" }.count, 1)
        XCTAssertLessThanOrEqual(staged.filter { $0.name == "state.vscdb-wal" }.count, 1)
        let mains = opened.filter { $0.lastPathComponent == "state.vscdb" }
        XCTAssertGreaterThanOrEqual(mains.count, 2)
        XCTAssertTrue(mains.allSatisfy { $0.path.hasPrefix(fixture.staging.path + "/") })
        XCTAssertTrue(mains.allSatisfy { !$0.path.hasPrefix(fixture.globalStorage.path + "/") })
        let globalURL = try XCTUnwrap(mains.first)
        XCTAssertEqual(Set(mains.map(\.path)).count, 2)
        XCTAssertGreaterThanOrEqual(mains.filter { $0.path == globalURL.path }.count, 2)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testFilesystemHiddenWorkspaceDoesNotSupplyOwnership_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("flag-hidden", folderURI: "file:///tmp/engram-legacy-ownership/flag-hidden",
            index: fixture.indexJSON(ids: ["owned"]))
        try fixture.flushAll()
        let directory = fixture.workspaceStorage.appendingPathComponent("flag-hidden")
        XCTAssertEqual(chflags(directory.path, UInt32(UF_HIDDEN)), 0)
        let visible = try FileManager.default.contentsOfDirectory(at: fixture.workspaceStorage,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        XCTAssertEqual(visible, [])
        XCTAssertEqual(try fixture.capture("owned").cwd, "")
    }

    func testStagingCannotWriteInsideWorkspaceInputTree_repro() throws {
        for useUserRoot in [false, true] {
            let fixture = try OwnershipFixture()
            defer { fixture.close() }
            try fixture.insertComposer("owned")
            try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/staging-boundary",
                index: fixture.indexJSON(ids: ["owned"]))
            try fixture.flushAll()
            let stagingRoot = useUserRoot ? fixture.userRoot : fixture.workspaceStorage
            var before = stat()
            XCTAssertEqual(lstat(stagingRoot.path, &before), 0)
            var staged: [String] = []
            assertLegacy(.sourceChanged) {
                try CollectorCursorLegacyOwnership.capture(globalStorageRoot: fixture.globalStorage,
                    composerID: "owned", stagingParent: stagingRoot,
                    testHooks: .init(rows: .init(snapshot: .init(didStageSourceFile: { name, _, _ in staged.append(name) }))))
            }
            XCTAssertEqual(staged, [])
            var after = stat()
            XCTAssertEqual(lstat(stagingRoot.path, &after), 0)
            XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
            XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
            XCTAssertEqual(after.st_ctimespec.tv_sec, before.st_ctimespec.tv_sec)
            XCTAssertEqual(after.st_ctimespec.tv_nsec, before.st_ctimespec.tv_nsec)
        }
    }

    func testLeaseSharesOneGlobalSnapshotAcrossDiscoveryAndMultipleCaptures() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("alpha", json: #"{"composerId":"alpha","text":"ALPHA-BODY"}"#)
        try fixture.insertComposer("beta", json: #"{"composerId":"beta","text":"BETA-BODY"}"#)
        try fixture.addWorkspace(
            "ws-alpha", folderURI: "file:///tmp/engram-legacy-ownership/lease-alpha",
            index: fixture.indexJSON(ids: ["alpha"]))
        try fixture.addWorkspace(
            "ws-beta", folderURI: "file:///tmp/engram-legacy-ownership/lease-beta",
            index: fixture.indexJSON(ids: ["beta"]))
        try fixture.flushAll()
        var opened: [URL] = []
        try fixture.withLease(testHooks: .init(beforeSQLiteOpen: { opened.append($0) })) { lease in
            XCTAssertEqual(try lease.composerIDs(limit: 1), ["alpha"])
            XCTAssertEqual(try lease.composerIDs(after: "alpha", limit: 1), ["beta"])
            XCTAssertEqual(try lease.composerIDs(after: "beta", limit: 1), [])
            let alpha = try lease.capture(composerID: "alpha")
            let beta = try lease.capture(composerID: "beta")
            XCTAssertEqual(alpha.rows.databaseGeneration, lease.databaseGeneration)
            XCTAssertEqual(beta.rows.databaseGeneration, lease.databaseGeneration)
            XCTAssertEqual(alpha.rows.walGeneration, lease.walGeneration)
            XCTAssertEqual(beta.rows.walGeneration, lease.walGeneration)
            XCTAssertEqual(alpha.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/lease-alpha"))
            XCTAssertEqual(beta.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/lease-beta"))
            XCTAssertNotNil(alpha.rows.composer.value?.range(of: Data("ALPHA-BODY".utf8)))
            XCTAssertNil(alpha.rows.composer.value?.range(of: Data("BETA-BODY".utf8)))
            XCTAssertNotNil(beta.rows.composer.value?.range(of: Data("BETA-BODY".utf8)))
            let globalImage = try XCTUnwrap(opened.first)
            XCTAssertTrue(globalImage.path.hasPrefix(fixture.staging.path + "/"))
            XCTAssertGreaterThan(
                opened.filter { $0.path.utf8.elementsEqual(globalImage.path.utf8) }.count, 1,
                "discovery and captures reopen one private global image")
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testLeaseDoesNotReopenUnchangedWorkspaceIndexesAcrossCaptures_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("alpha", json: #"{"composerId":"alpha","text":"ALPHA-BODY"}"#)
        try fixture.insertComposer("beta", json: #"{"composerId":"beta","text":"BETA-BODY"}"#)
        try fixture.addWorkspace(
            "ws-alpha", folderURI: "file:///tmp/engram-legacy-ownership/reuse-alpha",
            index: fixture.indexJSON(ids: ["alpha"]))
        try fixture.addWorkspace(
            "ws-beta", folderURI: "file:///tmp/engram-legacy-ownership/reuse-beta",
            index: fixture.indexJSON(ids: ["beta"]))
        try fixture.flushAll()
        var opened: [URL] = []
        try fixture.withLease(testHooks: .init(beforeSQLiteOpen: { opened.append($0) })) { lease in
            XCTAssertEqual(try lease.composerIDs(limit: 2), ["alpha", "beta"])
            let globalImage = try XCTUnwrap(opened.first)
            XCTAssertTrue(
                opened.allSatisfy { $0.lastPathComponent.utf8.elementsEqual("state.vscdb".utf8)
                    && $0.path.utf8.elementsEqual(globalImage.path.utf8) },
                "discovery must only open the shared global image")
            let alpha = try lease.capture(composerID: "alpha")
            let beta = try lease.capture(composerID: "beta")
            XCTAssertEqual(alpha.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/reuse-alpha"))
            XCTAssertEqual(beta.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/reuse-beta"))
            XCTAssertNotEqual(alpha.cwd, beta.cwd)
            let workspaceOpens = opened.filter {
                $0.lastPathComponent.utf8.elementsEqual("state.vscdb".utf8)
                    && !$0.path.utf8.elementsEqual(globalImage.path.utf8)
            }
            XCTAssertEqual(
                workspaceOpens.count, 2,
                "unchanged workspace indexes must be cloned once per lease, not once per composer")
            XCTAssertEqual(Set(workspaceOpens.map(\.path)).count, 2)
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testLeaseRejectsLiveSourceChangeBetweenCaptures() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("alpha")
        try fixture.insertComposer("beta")
        try fixture.addWorkspace(
            "ws-alpha", folderURI: "file:///tmp/engram-legacy-ownership/lease-change-a",
            index: fixture.indexJSON(ids: ["alpha"]))
        try fixture.addWorkspace(
            "ws-beta", folderURI: "file:///tmp/engram-legacy-ownership/lease-change-b",
            index: fixture.indexJSON(ids: ["beta"]))
        try fixture.flushAll()
        try fixture.withLease { lease in
            let first = try lease.capture(composerID: "alpha")
            XCTAssertEqual(first.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/lease-change-a"))
            try fixture.writeWorkspaceJSON(
                "ws-alpha", folderURI: "file:///tmp/engram-legacy-ownership/lease-change-a-moved")
            assertLegacy(.sourceChanged) {
                try lease.capture(composerID: "beta")
            }
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testLeaseRejectsOwnershipDatabaseChangeBetweenCachedCaptures_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("alpha")
        try fixture.insertComposer("beta")
        try fixture.addWorkspace(
            "ws-alpha", folderURI: "file:///tmp/engram-legacy-ownership/lease-db-a",
            index: fixture.indexJSON(ids: ["alpha"]))
        try fixture.addWorkspace(
            "ws-beta", folderURI: "file:///tmp/engram-legacy-ownership/lease-db-b",
            index: fixture.indexJSON(ids: ["beta"]))
        try fixture.flushAll()
        try fixture.withLease { lease in
            let first = try lease.capture(composerID: "alpha")
            XCTAssertEqual(first.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/lease-db-a"))
            try fixture.setWorkspaceIndex("ws-alpha", fixture.indexJSON(ids: ["alpha", "late"]))
            try fixture.flushAll()
            assertLegacy(.sourceChanged) {
                try lease.capture(composerID: "beta")
            }
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testLeaseAggregatesSQLiteAndOwnershipBudgetsAcrossThePage() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("alpha")
        try fixture.insertComposer("beta")
        try fixture.addWorkspace(
            "ws-alpha", folderURI: "file:///tmp/engram-legacy-ownership/lease-budget-a",
            index: fixture.indexJSON(ids: ["alpha"]))
        try fixture.addWorkspace(
            "ws-beta", folderURI: "file:///tmp/engram-legacy-ownership/lease-budget-b",
            index: fixture.indexJSON(ids: ["beta"]))
        try fixture.flushAll()
        let measured = try fixture.capture("alpha")
        var pages = 0
        assertLegacy(.exceededBudget) {
            try fixture.withLease(budget: .init(rows: .init(maximumOutputBytes: 64))) { lease in
                while pages < 32 {
                    let page = try lease.composerIDs(limit: 1)
                    XCTAssertEqual(page, ["alpha"])
                    pages += 1
                }
            }
        }
        XCTAssertGreaterThan(pages, 0, "one discovery page fits the shared output budget")
        XCTAssertLessThan(pages, 32, "repeated discovery cannot reset the lease output budget")

        try fixture.withLease(budget: .init(maximumOwnershipBytes: measured.ownershipPayloadByteCount)) { lease in
            let first = try lease.capture(composerID: "alpha")
            XCTAssertEqual(first.ownershipPayloadByteCount, measured.ownershipPayloadByteCount)
            assertLegacy(.exceededBudget) {
                try lease.capture(composerID: "beta")
            }
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testLeasePagesMultipleIDsWithDistinctOwnership() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("alpha", json: #"{"composerId":"alpha","secret":"ALPHA-ONLY"}"#)
        try fixture.insertComposer("beta", json: #"{"composerId":"beta","secret":"BETA-ONLY"}"#)
        try fixture.addWorkspace(
            "ws-alpha", folderURI: "file:///tmp/engram-legacy-ownership/lease-page-a",
            index: fixture.indexJSON(ids: ["alpha"]))
        try fixture.addWorkspace(
            "ws-beta", folderURI: "file:///tmp/engram-legacy-ownership/lease-page-b",
            index: fixture.indexJSON(ids: ["beta"]))
        try fixture.flushAll()
        try fixture.withLease { lease in
            XCTAssertEqual(try lease.composerIDs(limit: 1), ["alpha"])
            XCTAssertEqual(try lease.composerIDs(after: "alpha", limit: 1), ["beta"])
            let alpha = try lease.capture(composerID: "alpha")
            let beta = try lease.capture(composerID: "beta")
            XCTAssertEqual(alpha.rows.composerID, "alpha")
            XCTAssertEqual(beta.rows.composerID, "beta")
            XCTAssertEqual(alpha.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/lease-page-a"))
            XCTAssertEqual(beta.cwd, Self.cwd("file:///tmp/engram-legacy-ownership/lease-page-b"))
            XCTAssertNotEqual(alpha.cwd, beta.cwd)
            XCTAssertNil(alpha.rows.composer.value?.range(of: Data("BETA-ONLY".utf8)))
            XCTAssertNil(beta.rows.composer.value?.range(of: Data("ALPHA-ONLY".utf8)))
            assertLegacy(.invalidComposer) {
                try lease.capture(composerID: "missing")
            }
        }
        let escaped = try fixture.withLease { $0 }
        XCTAssertThrowsError(try escaped.composerIDs())
        XCTAssertThrowsError(try escaped.capture(composerID: "alpha"))
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testWorkspaceSHMSymlinkAppearingAfterReadIsRejected_repro() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.insertComposer("owned")
        try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/shm-boundary",
            index: fixture.indexJSON(ids: ["owned"]))
        try fixture.flushAll()
        let shm = URL(fileURLWithPath: fixture.workspaceDatabase("ws-a").path + "-shm")
        assertLegacy(.sourceChanged) {
            try fixture.capture("owned", testHooks: .init(beforeFinalValidation: {
                try FileManager.default.removeItem(at: shm)
                try FileManager.default.createSymbolicLink(at: shm, withDestinationURL: fixture.globalDatabase)
            }))
        }
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
    }

    func testOwnershipObservationMissingWorkspaceStorageIsStableAndDistinctFromEmpty() throws {
        let empty = try OwnershipFixture()
        defer { empty.close() }
        let present = try empty.observationPage(limit: 1)
        XCTAssertFalse(present.workspaceStorageMissing)
        XCTAssertEqual(present.workspaces, [])
        XCTAssertNil(present.nextAfter)
        XCTAssertTrue(present.membershipFingerprint.hasPrefix("cursor-legacy-ownership-membership-v1:"))
        XCTAssertEqual(try empty.observationPage(limit: 1), present)

        try FileManager.default.removeItem(at: empty.workspaceStorage)
        let missing = try empty.observationPage(limit: 8)
        XCTAssertTrue(missing.workspaceStorageMissing)
        XCTAssertEqual(missing.workspaces, [])
        XCTAssertNil(missing.nextAfter)
        XCTAssertNotEqual(missing.membershipFingerprint, present.membershipFingerprint)
        XCTAssertEqual(try empty.observationPage(after: nil, limit: 8), missing)
        XCTAssertTrue(try empty.stagingNames().isEmpty)
    }

    func testOwnershipObservationPagesMembershipAndOffPageAdd() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-a")
        try fixture.addWorkspace("ws-b", folderURI: "file:///tmp/engram-legacy-ownership/observe-b")
        try fixture.addWorkspace("ws-c", folderURI: "file:///tmp/engram-legacy-ownership/observe-c")
        let first = try fixture.observationPage(limit: 1)
        XCTAssertEqual(first.workspaces.map(\.workspaceID), ["ws-a"])
        XCTAssertEqual(first.nextAfter, "ws-a")
        XCTAssertFalse(first.workspaceStorageMissing)
        let second = try fixture.observationPage(after: first.nextAfter, limit: 1)
        XCTAssertEqual(second.workspaces.map(\.workspaceID), ["ws-b"])
        XCTAssertEqual(second.nextAfter, "ws-b")
        XCTAssertEqual(second.membershipFingerprint, first.membershipFingerprint)
        let last = try fixture.observationPage(after: "ws-b", limit: 2)
        XCTAssertEqual(last.workspaces.map(\.workspaceID), ["ws-c"])
        XCTAssertNil(last.nextAfter)
        let membership = first.membershipFingerprint
        try fixture.addWorkspace("ws-z", folderURI: "file:///tmp/engram-legacy-ownership/observe-z")
        let again = try fixture.observationPage(limit: 1)
        XCTAssertEqual(again.workspaces.map(\.workspaceID), ["ws-a"])
        XCTAssertEqual(again.nextAfter, "ws-a")
        XCTAssertNotEqual(again.membershipFingerprint, membership)
        XCTAssertEqual(again.workspaces[0].fingerprint, first.workspaces[0].fingerprint)
    }

    func testOwnershipObservationWorkspaceJSONAndWALChangeButSHMDoesNot() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-stat")
        try fixture.flushAll()
        try fixture.closeWorkspaceWriter("ws-a")
        let before = try fixture.observationPage(limit: 1)
        XCTAssertEqual(before.workspaces.map(\.workspaceID), ["ws-a"])
        try fixture.writeWorkspaceJSON("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-stat-moved")
        let afterJSON = try fixture.observationPage(limit: 1)
        XCTAssertEqual(afterJSON.membershipFingerprint, before.membershipFingerprint)
        XCTAssertNotEqual(afterJSON.workspaces[0].fingerprint, before.workspaces[0].fingerprint)
        try Data("wal-chatter".utf8).write(to: fixture.workspaceWAL("ws-a"))
        let afterWAL = try fixture.observationPage(limit: 1)
        XCTAssertEqual(afterWAL.membershipFingerprint, before.membershipFingerprint)
        XCTAssertNotEqual(afterWAL.workspaces[0].fingerprint, afterJSON.workspaces[0].fingerprint)
        try Data("shm-chatter".utf8).write(
            to: URL(fileURLWithPath: fixture.workspaceDatabase("ws-a").path + "-shm"))
        XCTAssertEqual(try fixture.observationPage(limit: 1), afterWAL)
    }

    func testOwnershipObservationRejectsSymlinkFollowAndSourceReplacement() throws {
        let linked = try OwnershipFixture()
        defer { linked.close() }
        try linked.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-link")
        try linked.closeWorkspaceWriter("ws-a")
        let foreign = linked.base.appendingPathComponent("foreign-workspaceStorage")
        try FileManager.default.moveItem(at: linked.workspaceStorage, to: foreign)
        try FileManager.default.createSymbolicLink(at: linked.workspaceStorage, withDestinationURL: foreign)
        assertLegacy(.sourceChanged) { try linked.observationPage(limit: 1) }

        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-replace")
        try fixture.closeWorkspaceWriter("ws-a")
        let json = fixture.workspaceStorage.appendingPathComponent("ws-a/workspace.json")
        let target = fixture.base.appendingPathComponent("workspace-target.json")
        try FileManager.default.moveItem(at: json, to: target)
        try FileManager.default.createSymbolicLink(at: json, withDestinationURL: target)
        let viaLink = try fixture.observationPage(limit: 1)
        try Data(#"{"folder":"file:///tmp/engram-legacy-ownership/observe-replace-target"}"#.utf8)
            .write(to: target)
        XCTAssertEqual(try fixture.observationPage(limit: 1), viaLink)

        try FileManager.default.removeItem(at: fixture.workspaceStorage.appendingPathComponent("ws-a"))
        try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-replace")
        let replaced = try fixture.observationPage(limit: 1)
        XCTAssertEqual(replaced.workspaces.map(\.workspaceID), ["ws-a"])
        XCTAssertEqual(replaced.membershipFingerprint, viaLink.membershipFingerprint)
        XCTAssertNotEqual(replaced.workspaces[0].fingerprint, viaLink.workspaces[0].fingerprint)
        try fixture.closeWorkspaceWriter("ws-a")
        let moved = fixture.base.appendingPathComponent("replaced-workspaceStorage")
        try FileManager.default.moveItem(at: fixture.workspaceStorage, to: moved)
        try FileManager.default.createDirectory(
            at: fixture.workspaceStorage, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-replace")
        let newRoot = try fixture.observationPage(limit: 1)
        XCTAssertNotEqual(newRoot.membershipFingerprint, viaLink.membershipFingerprint)
        XCTAssertEqual(newRoot.workspaces.map(\.workspaceID), ["ws-a"])
    }

    func testOwnershipObservationDoesNotReadSourceContentsAndHonorsBounds() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.close() }
        try fixture.addWorkspace("ws-a", folderURI: "file:///tmp/engram-legacy-ownership/observe-noread")
        try fixture.addWorkspace("ws-b", folderURI: "file:///tmp/engram-legacy-ownership/observe-noread-b")
        try fixture.flushAll()
        try fixture.closeSources()
        let json = fixture.workspaceStorage.appendingPathComponent("ws-a/workspace.json")
        let database = fixture.workspaceDatabase("ws-a")
        XCTAssertEqual(chmod(json.path, 0), 0)
        XCTAssertEqual(chmod(database.path, 0), 0)
        defer {
            _ = chmod(json.path, 0o600)
            _ = chmod(database.path, 0o600)
        }
        let page = try fixture.observationPage(
            limit: 2,
            testHooks: .init(
                beforeSQLiteOpen: { _ in XCTFail("observation must not open SQLite") },
                afterWorkspaceRead: { _ in XCTFail("observation must not read workspace bytes") },
                beforeFinalValidation: { XCTFail("observation must not capture") }
            )
        )
        XCTAssertEqual(page.workspaces.map(\.workspaceID), ["ws-a", "ws-b"])
        XCTAssertNil(page.nextAfter)
        XCTAssertTrue(try fixture.stagingNames().isEmpty)
        assertLegacy(.exceededBudget) { try fixture.observationPage(limit: 0) }
        assertLegacy(.exceededBudget) { try fixture.observationPage(limit: 65) }
        assertLegacy(.exceededBudget) { try fixture.observationPage(after: "", limit: 1) }
        assertLegacy(.exceededBudget) { try fixture.observationPage(after: ".", limit: 1) }
        assertLegacy(.exceededBudget) { try fixture.observationPage(after: "..", limit: 1) }
        assertLegacy(.exceededBudget) { try fixture.observationPage(after: "ws-a/extra", limit: 1) }
        assertLegacy(.exceededBudget) { try fixture.observationPage(after: "ws-a\0z", limit: 1) }
        assertLegacy(.exceededBudget) {
            try fixture.observationPage(limit: 1, budget: .init(maximumWorkspaces: 1))
        }
        assertLegacy(.sourceChanged) { try fixture.observationPage(limit: 1, root: fixture.userRoot) }
        try fixture.addWorkspace(".dot", folderURI: "file:///tmp/engram-legacy-ownership/observe-dot")
        let hidden = fixture.workspaceStorage.appendingPathComponent("flag-hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        XCTAssertEqual(chflags(hidden.path, UInt32(UF_HIDDEN)), 0)
        let visible = try fixture.observationPage(limit: 8)
        XCTAssertEqual(visible.workspaces.map(\.workspaceID), ["ws-a", "ws-b"])
    }

    private static func cwd(_ folderURI: String) -> String {
        URL(string: folderURI)?.standardizedFileURL.path ?? ""
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

private func assertWithheld(
    forbiddenCwd: String,
    _ work: () throws -> CollectorCursorLegacyOwnership.Capture,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    do {
        let captured = try work()
        XCTAssertEqual(captured.cwd, "", file: file, line: line)
        XCTAssertNotEqual(captured.cwd, forbiddenCwd, file: file, line: line)
        XCTAssertEqual(captured.rows.composerID, "owned", file: file, line: line)
    } catch let error as CollectorCursorLegacySource.LegacyError {
        XCTAssertNotEqual(error, .invalidComposer, file: file, line: line)
        XCTAssertNotEqual(error, .exceededBudget, file: file, line: line)
    }
}

private final class OwnershipFixture {
    let base: URL
    let userRoot: URL
    let globalStorage: URL
    let workspaceStorage: URL
    let staging: URL
    private var globalWriter: OpaquePointer?
    private var workspaceWriters: [String: OpaquePointer] = [:]

    var globalDatabase: URL { globalStorage.appendingPathComponent("state.vscdb") }
    var globalWAL: URL { URL(fileURLWithPath: globalDatabase.path + "-wal") }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-cursor-legacy-ownership-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let physical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical))
        userRoot = base.appendingPathComponent("User")
        globalStorage = userRoot.appendingPathComponent("globalStorage")
        workspaceStorage = userRoot.appendingPathComponent("workspaceStorage")
        staging = base.appendingPathComponent("private-staging")
        for directory in [globalStorage, workspaceStorage, staging] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        globalWriter = try Self.openWriter(at: globalDatabase)
        try sql(globalWriter, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try sql(globalWriter, """
            CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
            """)
    }

    func insertComposer(_ id: String, json: String? = nil) throws {
        let value = json ?? #"{"composerId":"\#(id)"}"#
        try insert(into: globalWriter, table: "cursorDiskKV", key: Data("composerData:\(id)".utf8), value: Data(value.utf8))
    }

    func insertComposer(utf8 id: Data) throws {
        let key = Data("composerData:".utf8) + id
        let value = Data(#"{"composerId":""#.utf8) + id + Data(#""}"#.utf8)
        try insert(into: globalWriter, table: "cursorDiskKV", key: key, value: value)
    }

    func setHeaders(_ value: Data) throws {
        try replace(into: globalWriter, key: Data("composer.composerHeaders".utf8), value: value)
    }

    func dropGlobalItemTable() throws {
        try sql(globalWriter, "DROP TABLE ItemTable;")
    }

    func writeRawWorkspaceJSON(_ id: String, _ data: Data) throws {
        try data.write(to: workspaceStorage.appendingPathComponent(id).appendingPathComponent("workspace.json"))
    }

    func removeWorkspaceJSON(_ id: String) throws {
        try FileManager.default.removeItem(
            at: workspaceStorage.appendingPathComponent(id).appendingPathComponent("workspace.json")
        )
    }

    func closeWorkspaceWriter(_ id: String) {
        if let writer = workspaceWriters.removeValue(forKey: id) {
            XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        }
    }

    func indexJSON(ids: [String]) -> Data {
        indexJSON(ids: ids.map { Data($0.utf8) })
    }

    func indexJSON(ids: [Data]) -> Data {
        var body = Data(#"{"allComposers":["#.utf8)
        for (offset, id) in ids.enumerated() {
            if offset > 0 { body.append(contentsOf: ",".utf8) }
            body.append(contentsOf: #"{"composerId":""#.utf8)
            body.append(id)
            body.append(contentsOf: #""}"#.utf8)
        }
        body.append(contentsOf: "]}".utf8)
        return body
    }

    func paddedIndex(id: String, pad: Int) -> Data {
        var body = Data(#"{"allComposers":[{"composerId":""#.utf8)
        body.append(contentsOf: id.utf8)
        body.append(contentsOf: #""}],"pad":""#.utf8)
        body.append(contentsOf: Array(repeating: UInt8(ascii: "x"), count: pad))
        body.append(contentsOf: #""}"#.utf8)
        return body
    }

    func headersJSON(_ entries: [(String, String)]) -> Data {
        var body = Data(#"{"allComposers":["#.utf8)
        for (offset, entry) in entries.enumerated() {
            if offset > 0 { body.append(contentsOf: ",".utf8) }
            body.append(contentsOf: #"{"composerId":""#.utf8)
            body.append(contentsOf: entry.0.utf8)
            body.append(contentsOf: #"","workspaceIdentifier":{"id":""#.utf8)
            body.append(contentsOf: entry.1.utf8)
            body.append(contentsOf: #""}}"#.utf8)
        }
        body.append(contentsOf: "]}".utf8)
        return body
    }

    func addWorkspace(
        _ id: String, folderURI: String, configurationJSON: String? = nil,
        index: Data? = nil, createDatabase: Bool = true
    ) throws {
        let directory = workspaceStorage.appendingPathComponent(id)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        try writeWorkspaceJSON(id, folderURI: folderURI, configurationJSON: configurationJSON)
        if createDatabase {
            try openWorkspaceDatabase(at: directory, id: id)
            if let index {
                try setWorkspaceIndex(id, index)
            }
        }
    }

    func writeWorkspaceJSON(_ id: String, folderURI: String, configurationJSON: String? = nil) throws {
        var json = Data(#"{"folder":""#.utf8)
        json.append(contentsOf: folderURI.utf8)
        json.append(contentsOf: #"""#.utf8)
        if let configurationJSON {
            json.append(contentsOf: #","configuration":"#.utf8)
            json.append(contentsOf: configurationJSON.utf8)
        }
        json.append(contentsOf: "}".utf8)
        try json.write(to: workspaceStorage.appendingPathComponent(id).appendingPathComponent("workspace.json"))
    }

    func openWorkspaceDatabase(at directory: URL, id: String) throws {
        let database = directory.appendingPathComponent("state.vscdb")
        let writer = try Self.openWriter(at: database)
        workspaceWriters[id] = writer
        try sql(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try sql(writer, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT);")
    }

    func setWorkspaceIndex(_ id: String, _ value: Data) throws {
        try replace(into: workspaceWriters[id], key: Data("composer.composerData".utf8), value: value)
    }

    func prepareEmptyWALSchema(workspace id: String) throws {
        try sql(workspaceWriters[id], "PRAGMA user_version=7; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func installAlternateGlobalStorage(_ name: String) throws {
        let root = userRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let writer = try Self.openWriter(at: root.appendingPathComponent("state.vscdb"))
        workspaceWriters[name] = writer
        try sql(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try sql(writer, """
            CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
            """)
        try insert(
            into: writer, table: "cursorDiskKV",
            key: Data("composerData:owned".utf8), value: Data(#"{"composerId":"owned"}"#.utf8)
        )
    }

    func capture(
        _ composerID: String, root: URL? = nil,
        budget: CollectorCursorLegacyOwnership.Budget = .init(),
        testHooks: CollectorCursorLegacyOwnership.TestHooks = .init()
    ) throws -> CollectorCursorLegacyOwnership.Capture {
        try CollectorCursorLegacyOwnership.capture(
            globalStorageRoot: root ?? globalStorage, composerID: composerID, stagingParent: staging,
            budget: budget, testHooks: testHooks
        )
    }

    func capture(
        utf8 composerID: Data,
        budget: CollectorCursorLegacyOwnership.Budget = .init(),
        testHooks: CollectorCursorLegacyOwnership.TestHooks = .init()
    ) throws -> CollectorCursorLegacyOwnership.Capture {
        try capture(String(decoding: composerID, as: UTF8.self), budget: budget, testHooks: testHooks)
    }

    func withLease<T>(
        budget: CollectorCursorLegacyOwnership.Budget = .init(),
        testHooks: CollectorCursorLegacyOwnership.TestHooks = .init(),
        _ body: (CollectorCursorLegacyOwnership.SnapshotLease) throws -> T
    ) throws -> T {
        try CollectorCursorLegacyOwnership.withSnapshotLease(
            globalStorageRoot: globalStorage, stagingParent: staging,
            budget: budget, testHooks: testHooks, body)
    }

    func observationPage(
        after: String? = nil, limit: Int,
        root: URL? = nil,
        budget: CollectorCursorLegacyOwnership.Budget = .init(),
        testHooks: CollectorCursorLegacyOwnership.TestHooks = .init()
    ) throws -> CollectorCursorLegacyOwnership.OwnershipObservationPage {
        try CollectorCursorLegacyOwnership.ownershipObservationPage(
            globalStorageRoot: root ?? globalStorage, after: after, limit: limit,
            budget: budget, testHooks: testHooks)
    }

    func workspaceDatabase(_ id: String) -> URL {
        workspaceStorage.appendingPathComponent(id).appendingPathComponent("state.vscdb")
    }

    func workspaceWAL(_ id: String) -> URL {
        URL(fileURLWithPath: workspaceDatabase(id).path + "-wal")
    }

    func flushAll() throws {
        try flush(globalWriter)
        for writer in workspaceWriters.values { try flush(writer) }
    }

    func globalBytes() throws -> [String: Data] {
        try bytes(around: globalDatabase)
    }

    func workspaceBytes(_ id: String) throws -> [String: Data] {
        try bytes(around: workspaceDatabase(id))
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

    func closeSources() {
        if let globalWriter {
            XCTAssertEqual(sqlite3_close(globalWriter), SQLITE_OK)
            self.globalWriter = nil
        }
        for (id, writer) in workspaceWriters {
            XCTAssertEqual(sqlite3_close(writer), SQLITE_OK, id)
        }
        workspaceWriters.removeAll()
    }

    func close() {
        closeSources()
        try? FileManager.default.removeItem(at: base)
    }

    private func bytes(around database: URL) throws -> [String: Data] {
        var values: [String: Data] = ["": try Data(contentsOf: database)]
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                values[suffix] = try Data(contentsOf: url)
            }
        }
        return values
    }

    private func insert(into writer: OpaquePointer?, table: String, key: Data, value: Data) throws {
        guard let writer else { throw POSIXError(.EIO) }
        let sql: String
        switch table {
        case "cursorDiskKV": sql = "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)"
        case "ItemTable": sql = "INSERT INTO ItemTable(key, value) VALUES (?, ?)"
        default: throw POSIXError(.EINVAL)
        }
        try run(writer, sql, key: key, value: value)
    }

    private func replace(into writer: OpaquePointer?, key: Data, value: Data) throws {
        guard let writer else { throw POSIXError(.EIO) }
        try run(writer, "INSERT OR REPLACE INTO ItemTable(key, value) VALUES (?, ?)", key: key, value: value)
    }

    private func run(_ writer: OpaquePointer, _ sql: String, key: Data, value: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try bindText(statement, 1, key, transient)
        try bindText(statement, 2, value, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw POSIXError(.EIO) }
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

    private func sql(_ writer: OpaquePointer?, _ value: String) throws {
        guard let writer else { throw POSIXError(.EIO) }
        var errmsg: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(writer, value, nil, nil, &errmsg)
        let message = errmsg.map { String(cString: $0) }
        sqlite3_free(errmsg)
        guard status == SQLITE_OK else {
            throw NSError(
                domain: "OwnershipFixture.sql", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message ?? "sqlite3_exec"]
            )
        }
    }

    private func flush(_ writer: OpaquePointer?) throws {
        guard let writer, sqlite3_db_cacheflush(writer) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    private static func openWriter(at database: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw POSIXError(.EIO) }
        return handle
    }
}

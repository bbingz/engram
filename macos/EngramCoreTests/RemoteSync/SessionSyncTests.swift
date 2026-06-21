import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

/// Layer 2 (session-record) sync data layer: publish-only ledger writes, manifest
/// build, and idempotent peer import. No schema migration — import state lives on
/// the existing sessions columns (origin / authoritative_node / snapshot_hash).
final class SessionSyncTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-syncrec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func freshWriter(_ name: String) throws -> EngramDatabaseWriter {
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("\(name).sqlite").path)
        try writer.migrate()
        return writer
    }

    private func insertLocalSession(
        _ db: Database, id: String, project: String = "demo", cwd: String = "/Users/bing/-Code-/demo",
        fts: [String] = ["hello", "world"]
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(id, source, start_time, end_time, cwd, project,
                                 message_count, user_message_count, assistant_message_count,
                                 summary, summary_message_count, generated_title, file_path, size_bytes)
            VALUES (?, 'codex', '2024-01-01T00:00:00Z', '2024-01-01T01:00:00Z', ?, ?,
                    2, 1, 1, 'a summary', 2, 'Title', '/tmp/\(id).jsonl', 1234)
            """,
            arguments: [id, cwd, project]
        )
        for line in fts {
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)", arguments: [id, line])
        }
    }

    // MARK: - publishOnlyCommit

    func testPublishOnlyCommitInsertsOutRowAndPreservesLocalState() throws {
        let writer = try freshWriter("publish")
        try writer.write { db in try insertLocalSession(db, id: "s1") }

        try writer.write { db in
            try OffloadRepo.publishOnlyCommit(
                db, sessionId: "s1", remoteKey: "h1.bundle", remoteSessionId: "s1",
                contentHash: "h1", peer: "macA"
            )
        }
        try writer.read { db in
            let outRows = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's1' AND direction = 'out'"
            )
            XCTAssertEqual(outRows, 1, "publish inserts exactly one 'out' ledger row")
            let remoteSession = try String.fetchOne(
                db, sql: "SELECT remote_session_id FROM sync_ledger WHERE session_id = 's1'"
            )
            XCTAssertEqual(remoteSession, "s1")
            // MUST NOT collapse FTS or flip offload_state (unlike commitOffloaded).
            let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = 's1'")
            XCTAssertEqual(ftsCount, 2, "publish must NOT collapse local FTS")
            XCTAssertEqual(try OffloadRepo.offloadState(db, sessionId: "s1"), "local",
                           "publish must NOT flip offload_state")
        }
    }

    func testPublishOnlyCommitIsIdempotentPerContentHash() throws {
        let writer = try freshWriter("publish-dedup")
        try writer.write { db in try insertLocalSession(db, id: "s1") }
        try writer.write { db in
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
        }
        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's1'"), 1,
                "re-publishing the same content hash is a no-op"
            )
        }
        // A new content hash records a new 'out' row.
        try writer.write { db in
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h2.bundle",
                                              remoteSessionId: "s1", contentHash: "h2", peer: "macA")
        }
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_ledger WHERE session_id = 's1'"), 2)
        }
    }

    // MARK: - pushCandidates

    func testPushCandidatesExcludeImportedSkipSubagent() throws {
        let writer = try freshWriter("candidates")
        try writer.write { db in
            try insertLocalSession(db, id: "local-1")
            // imported (origin = a peer) — must be excluded (echo-loop guard)
            try insertLocalSession(db, id: "imported-1")
            try db.execute(sql: "UPDATE sessions SET origin = 'macB' WHERE id = 'imported-1'")
            // skip tier — excluded
            try insertLocalSession(db, id: "skip-1")
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = 'skip-1'")
            // child session — excluded
            try insertLocalSession(db, id: "child-1")
            try db.execute(sql: "UPDATE sessions SET parent_session_id = 'local-1' WHERE id = 'child-1'")
            // already offloaded — excluded (pushing it would republish the collapsed
            // FTS shadow and overwrite the rehydrate ledger key)
            try insertLocalSession(db, id: "offloaded-1")
            try db.execute(sql: "UPDATE sessions SET offload_state = 'offloaded' WHERE id = 'offloaded-1'")
            // subagent by agent_role (tier NOT skip) — excluded (defense-in-depth)
            try insertLocalSession(db, id: "subagent-1")
            try db.execute(sql: "UPDATE sessions SET agent_role = 'subagent' WHERE id = 'subagent-1'")
        }
        let candidates = try writer.read { db in
            try OffloadRepo.pushCandidates(db, project: "demo", cwd: "/Users/bing/-Code-/demo")
        }
        XCTAssertEqual(candidates.map(\.id), ["local-1"],
                       "only local-origin, non-skip, non-subagent, non-offloaded, top-level sessions")
        XCTAssertEqual(candidates.first?.ftsContents, ["hello", "world"])
        XCTAssertEqual(candidates.first?.title, "Title")
    }

    func testPushCandidatesScopeByCaseInsensitiveProjectOrCwd() throws {
        let writer = try freshWriter("scope")
        try writer.write { db in
            // Mismatched-case project but matching cwd → still scoped in.
            try insertLocalSession(db, id: "s1", project: "readout", cwd: "/Users/bing/-Code-/ReadOut")
            // Matching project (case-insensitive), unrelated cwd.
            try insertLocalSession(db, id: "s2", project: "ReadOut", cwd: "/somewhere/else")
            // Unrelated.
            try insertLocalSession(db, id: "s3", project: "other", cwd: "/x")
        }
        let candidates = try writer.read { db in
            try OffloadRepo.pushCandidates(db, project: "ReadOut", cwd: "/Users/bing/-Code-/ReadOut")
        }
        XCTAssertEqual(Set(candidates.map(\.id)), ["s1", "s2"])
    }

    func testPushCandidatesBlankCwdDoesNotOverMatchEmptyCwdSessions() throws {
        let writer = try freshWriter("blank-cwd")
        try writer.write { db in
            // Matching project, empty cwd → still returned via the project-only branch.
            try insertLocalSession(db, id: "match", project: "demo", cwd: "")
            // Unrelated project, empty cwd → must NOT be swept in when the cwd arg is
            // blank (the regression: `cwd = ''` matched every empty-cwd session).
            try insertLocalSession(db, id: "unrelated", project: "other", cwd: "")
        }
        let candidates = try writer.read { db in
            try OffloadRepo.pushCandidates(db, project: "demo", cwd: "")
        }
        XCTAssertEqual(candidates.map(\.id), ["match"],
                       "a blank cwd falls back to project-only matching; empty-cwd sessions of other projects are not over-matched")
    }

    // MARK: - publishedManifestEntries

    func testPublishedManifestEntriesJoinLatestOutLedger() throws {
        let writer = try freshWriter("manifest")
        try writer.write { db in
            try insertLocalSession(db, id: "s1")
            try insertLocalSession(db, id: "s2") // never published → excluded from manifest
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h2.bundle",
                                              remoteSessionId: "s1", contentHash: "h2", peer: "macA")
        }
        let entries = try writer.read { db in
            try OffloadRepo.publishedManifestEntries(db, project: "demo",
                                                     cwd: "/Users/bing/-Code-/demo", peer: "macA")
        }
        XCTAssertEqual(entries.count, 1, "only published sessions appear")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, "s1")
        XCTAssertEqual(entry.remoteKey, "h2.bundle", "latest 'out' row wins")
        XCTAssertEqual(entry.contentHash, "h2")
        XCTAssertEqual(entry.title, "Title")
        XCTAssertEqual(entry.messageCount, 2)
    }

    func testPublishedManifestEntriesNormalizeProjectToRequested() throws {
        let writer = try freshWriter("manifest-normalize")
        try writer.write { db in
            // cwd-matched session whose stored project is blank/divergent from the
            // requested name — its entry must carry the REQUESTED project so the
            // pull side (which matches on project name only, no cwd) can find it.
            try insertLocalSession(db, id: "s1", project: "", cwd: "/Users/bing/-Code-/ReadOut")
            try OffloadRepo.publishOnlyCommit(db, sessionId: "s1", remoteKey: "h1.bundle",
                                              remoteSessionId: "s1", contentHash: "h1", peer: "macA")
        }
        let entries = try writer.read { db in
            try OffloadRepo.publishedManifestEntries(db, project: "ReadOut",
                                                     cwd: "/Users/bing/-Code-/ReadOut", peer: "macA")
        }
        XCTAssertEqual(entries.map(\.project), ["ReadOut"],
                       "cwd-only-matched entry project is normalized to the requested name (importable on pull)")
    }

    // MARK: - ImportRepo

    private func makeEntryAndBundle(
        sessionId: String, peer _: String, hash: String, fts: [String]
    ) -> (SyncManifestEntry, RemoteSessionBundle) {
        let bundle = BundleCodec.makeBundle(
            sessionId: sessionId, ftsContents: fts, summary: "remote summary", summaryMessageCount: 2,
            messageCount: 2, userMessageCount: 1, assistantMessageCount: 1,
            toolMessageCount: 0, systemMessageCount: 0
        )
        let entry = SyncManifestEntry(
            sessionId: sessionId, source: "codex", project: "demo", title: "Remote Title",
            startTime: "2024-02-02T00:00:00Z", endTime: "2024-02-02T01:00:00Z",
            messageCount: 2, userMessageCount: 1, assistantMessageCount: 1,
            systemMessageCount: 0, toolMessageCount: 0, summary: "entry summary",
            summaryMessageCount: 2, sizeBytes: 4096, tier: "normal",
            remoteKey: "\(hash).bundle", contentHash: hash
        )
        return (entry, bundle)
    }

    func testCommitImportedCreatesSearchableRowWithPeerOrigin() throws {
        let writer = try freshWriter("import")
        let (entry, bundle) = makeEntryAndBundle(
            sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["alpha bravo", "charlie delta"]
        )
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }

        let localId = ImportRepo.importedLocalId(peer: "macB", sessionId: "rs1")
        XCTAssertEqual(localId, "remote:macB:rs1")
        try writer.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT origin, authoritative_node, snapshot_hash, summary, file_path, offload_state, cwd, generated_title FROM sessions WHERE id = ?",
                arguments: [localId]
            ))
            XCTAssertEqual(row["origin"], "macB")
            XCTAssertEqual(row["authoritative_node"], "macB")
            XCTAssertEqual(row["snapshot_hash"], "ih1")
            XCTAssertEqual(row["summary"], "remote summary", "bundle summary wins over entry summary")
            XCTAssertEqual(row["file_path"], "remote://macB/rs1")
            XCTAssertEqual(row["offload_state"], "local")
            XCTAssertEqual(row["cwd"], "")
            XCTAssertEqual(row["generated_title"], "Remote Title")
            // searchable: imported FTS content present
            let hits = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ? AND content MATCH 'bravo'",
                arguments: [localId]
            )
            XCTAssertEqual(hits, 1, "imported session is keyword searchable")
        }
    }

    func testCommitImportedIsIdempotentAndUpdatesInPlace() throws {
        let writer = try freshWriter("import-idem")
        let (entry, bundle) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["one two"])
        let localId = ImportRepo.importedLocalId(peer: "macB", sessionId: "rs1")

        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        // Re-import same hash → no duplicate, single row.
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [localId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_fts WHERE session_id = ?", arguments: [localId]), 1)
        }
        // Different hash → updates in place (new title + FTS), still one row.
        let (entry2, bundle2) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih2", fts: ["three four", "five six"])
        let updated = SyncManifestEntry(
            sessionId: entry2.sessionId, source: entry2.source, project: entry2.project, title: "Updated Title",
            startTime: entry2.startTime, endTime: entry2.endTime, messageCount: entry2.messageCount,
            userMessageCount: entry2.userMessageCount, assistantMessageCount: entry2.assistantMessageCount,
            systemMessageCount: entry2.systemMessageCount, toolMessageCount: entry2.toolMessageCount,
            summary: entry2.summary, summaryMessageCount: entry2.summaryMessageCount, sizeBytes: entry2.sizeBytes,
            tier: entry2.tier, remoteKey: entry2.remoteKey, contentHash: entry2.contentHash
        )
        try writer.write { db in try ImportRepo.commitImported(db, entry: updated, peer: "macB", bundle: bundle2) }
        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [localId]), 1,
                           "re-import updates in place, no duplicate row")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT snapshot_hash FROM sessions WHERE id = ?", arguments: [localId]), "ih2")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id = ?", arguments: [localId]), "Updated Title")
            let restored = Set(try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?", arguments: [localId]))
            XCTAssertEqual(restored, Set(["three four", "five six"]), "FTS replaced with new content")
        }
    }

    /// The load-bearing invariant: re-import must UPSERT (UPDATE in place), NOT
    /// `INSERT OR REPLACE` (delete-then-insert), so a session's ON DELETE CASCADE
    /// children survive every re-pull. Plants a `session_local_state` child and
    /// asserts it survives a changed-hash re-import. Fails immediately under REPLACE.
    func testCommitImportedPreservesCascadeChildrenOnReimport() throws {
        let writer = try freshWriter("import-cascade")
        let (entry, bundle) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["one"])
        let localId = ImportRepo.importedLocalId(peer: "macB", sessionId: "rs1")

        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        // Plant an ON DELETE CASCADE child keyed by the imported row.
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO session_local_state(session_id, custom_name) VALUES (?, 'pinned')",
                arguments: [localId]
            )
        }
        // Re-import with a CHANGED hash → row updated in place; the child must survive.
        let (entry2, bundle2) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih2", fts: ["two"])
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry2, peer: "macB", bundle: bundle2) }
        try writer.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_local_state WHERE session_id = ?", arguments: [localId]),
                1, "UPSERT must preserve cascade children; INSERT OR REPLACE would delete them"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT custom_name FROM session_local_state WHERE session_id = ?", arguments: [localId]),
                "pinned", "child row content intact across re-import"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT snapshot_hash FROM sessions WHERE id = ?", arguments: [localId]),
                "ih2", "session row itself updated in place"
            )
        }
    }

    func testNeedsImportLogic() throws {
        let writer = try freshWriter("needs")
        let (entry, bundle) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        try writer.read { db in
            XCTAssertTrue(try ImportRepo.needsImport(db, peer: "macB", entry: entry), "never imported → needs import")
        }
        try writer.write { db in try ImportRepo.commitImported(db, entry: entry, peer: "macB", bundle: bundle) }
        try writer.read { db in
            XCTAssertFalse(try ImportRepo.needsImport(db, peer: "macB", entry: entry), "same hash → no import")
        }
        let changed = SyncManifestEntry(
            sessionId: entry.sessionId, source: entry.source, project: entry.project, title: entry.title,
            startTime: entry.startTime, endTime: entry.endTime, messageCount: entry.messageCount,
            userMessageCount: entry.userMessageCount, assistantMessageCount: entry.assistantMessageCount,
            systemMessageCount: entry.systemMessageCount, toolMessageCount: entry.toolMessageCount,
            summary: entry.summary, summaryMessageCount: entry.summaryMessageCount, sizeBytes: entry.sizeBytes,
            tier: entry.tier, remoteKey: "ih9.bundle", contentHash: "ih9"
        )
        try writer.read { db in
            XCTAssertTrue(try ImportRepo.needsImport(db, peer: "macB", entry: changed), "different hash → needs re-import")
        }
    }

    // MARK: - ManifestCodec

    func testManifestCodecRoundTrip() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let data = try ManifestCodec.encode(manifest)
        let decoded = try ManifestCodec.decode(data)
        XCTAssertEqual(decoded, manifest)
    }

    func testDecodeCatalogSkipsCorruptManifests() throws {
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let good = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        let goodObj = try JSONSerialization.jsonObject(with: ManifestCodec.encode(good))
        // Aggregated catalog with one valid + one corrupt manifest object.
        let corrupt: [String: Any] = ["peer": "macC", "garbage": true] // missing required fields
        let catalog: [String: Any] = ["schemaVersion": 1, "manifests": [goodObj, corrupt]]
        let data = try JSONSerialization.data(withJSONObject: catalog)
        let manifests = ManifestCodec.decodeCatalog(data)
        XCTAssertEqual(manifests.count, 1, "corrupt manifest skipped, valid one survives")
        XCTAssertEqual(manifests.first, good)
    }

    /// LocalDirectoryBackend.catalog() selects ONLY `catalog.<peer>.manifest` blobs
    /// (via ManifestCodec.isManifestKey), matching the server route's predicate: a
    /// `catalog.*` blob without the `.manifest` suffix and a `catalog..manifest` key
    /// (rejected by the server's BlobStore.validate) are both excluded here too.
    func testLocalCatalogSelectsOnlyManifestKeys() async throws {
        let dir = tempDir.appendingPathComponent("catalog-store", isDirectory: true)
        let backend = try LocalDirectoryBackend(root: dir)
        let (entry, _) = makeEntryAndBundle(sessionId: "rs1", peer: "macB", hash: "ih1", fts: ["x"])
        let manifest = SyncManifest(peer: "macB", updatedAt: "2024-02-02T00:00:00Z", entries: [entry])
        try await backend.put(key: ManifestCodec.manifestKey(peer: "macB"), data: ManifestCodec.encode(manifest))
        try await backend.put(key: "catalog.stray", data: Data("{}".utf8))         // no .manifest suffix
        try await backend.put(key: "catalog..manifest", data: Data("{}".utf8))     // contains ".."
        let catalogData = try await backend.catalog()
        let manifests = ManifestCodec.decodeCatalog(catalogData)
        XCTAssertEqual(manifests, [manifest],
                       "only catalog.<peer>.manifest blobs are aggregated; stray and '..' keys excluded")
    }
}

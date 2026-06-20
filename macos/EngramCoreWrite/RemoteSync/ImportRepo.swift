import Foundation
import GRDB

/// Pull-side mutations for Layer 2 session-record sync: turn a peer's manifest
/// entry + its content bundle into a LOCAL imported `sessions` row that is keyword
/// searchable, with NO schema migration. Import state lives on the existing
/// columns: `origin` / `authoritative_node` = the publishing peer, and
/// `snapshot_hash` = the bundle content hash (the dedup key for re-pull).
///
/// Imported rows use a DETERMINISTIC id `remote:<peer>:<sessionId>` so a re-pull
/// UPSERTs the same row in place (idempotent) instead of duplicating. We use
/// SQLite UPSERT (`ON CONFLICT(id) DO UPDATE`) rather than `INSERT OR REPLACE`,
/// because REPLACE deletes-then-inserts and would cascade FK child deletes.
public enum ImportRepo {
    /// Deterministic local id for an imported session.
    public static func importedLocalId(peer: String, sessionId: String) -> String {
        "remote:\(peer):\(sessionId)"
    }

    /// True if this peer entry has never been imported, or its stored
    /// `snapshot_hash` differs from the entry's current content hash (re-pull).
    public static func needsImport(_ db: Database, peer: String, entry: SyncManifestEntry) throws -> Bool {
        let localId = importedLocalId(peer: peer, sessionId: entry.sessionId)
        guard let stored = try String.fetchOne(
            db, sql: "SELECT snapshot_hash FROM sessions WHERE id = ?", arguments: [localId]
        ) else {
            return true
        }
        return stored != entry.contentHash
    }

    /// UPSERT the imported session row + replace its FTS content. Idempotent:
    /// re-importing the same hash overwrites identical values (no duplicate row);
    /// a changed hash updates the existing row in place. `cwd` is left empty — an
    /// imported session has no local working directory.
    public static func commitImported(
        _ db: Database,
        entry: SyncManifestEntry,
        peer: String,
        bundle: RemoteSessionBundle
    ) throws {
        let localId = importedLocalId(peer: peer, sessionId: entry.sessionId)
        let filePath = "remote://\(peer)/\(entry.sessionId)"
        try db.execute(
            sql: """
            INSERT INTO sessions(
                id, source, start_time, end_time, cwd, project,
                message_count, user_message_count, assistant_message_count,
                system_message_count, tool_message_count,
                summary, summary_message_count, file_path, size_bytes,
                origin, authoritative_node, tier, generated_title,
                snapshot_hash, offload_state, indexed_at
            ) VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'local', datetime('now'))
            ON CONFLICT(id) DO UPDATE SET
                source = excluded.source,
                start_time = excluded.start_time,
                end_time = excluded.end_time,
                project = excluded.project,
                message_count = excluded.message_count,
                user_message_count = excluded.user_message_count,
                assistant_message_count = excluded.assistant_message_count,
                system_message_count = excluded.system_message_count,
                tool_message_count = excluded.tool_message_count,
                summary = excluded.summary,
                summary_message_count = excluded.summary_message_count,
                file_path = excluded.file_path,
                size_bytes = excluded.size_bytes,
                origin = excluded.origin,
                authoritative_node = excluded.authoritative_node,
                tier = excluded.tier,
                generated_title = excluded.generated_title,
                snapshot_hash = excluded.snapshot_hash,
                indexed_at = datetime('now')
            """,
            arguments: [
                localId, entry.source, entry.startTime, entry.endTime, entry.project,
                entry.messageCount, entry.userMessageCount, entry.assistantMessageCount,
                entry.systemMessageCount, entry.toolMessageCount,
                bundle.summary ?? entry.summary, entry.summaryMessageCount, filePath, entry.sizeBytes,
                peer, peer, entry.tier, entry.title,
                entry.contentHash,
            ]
        )
        try FTSRebuildPolicy.replaceFtsContent(db, sessionId: localId, contents: bundle.ftsContents)
    }
}

import Foundation
import EngramCoreRead
import GRDB

enum ArchiveCatalogMigrations {
    static let currentSchemaVersion = "4"

    static func migrate(_ db: Database, machineID: String) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        ) WITHOUT ROWID
        """)

        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_captures (
            capture_id TEXT PRIMARY KEY NOT NULL,
            machine_id TEXT NOT NULL,
            source TEXT NOT NULL,
            locator TEXT NOT NULL,
            generation_device INTEGER NOT NULL,
            generation_inode INTEGER NOT NULL,
            generation_size INTEGER NOT NULL,
            generation_mtime_ns INTEGER NOT NULL,
            generation_ctime_ns INTEGER NOT NULL,
            generation_mode INTEGER NOT NULL,
            whole_source_sha256 TEXT NOT NULL,
            raw_byte_count INTEGER NOT NULL,
            chunk_size INTEGER NOT NULL,
            unbound_manifest_sha256 TEXT NOT NULL UNIQUE,
            unbound_manifest_bytes BLOB NOT NULL,
            status TEXT NOT NULL,
            diagnostic TEXT,
            captured_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        ) WITHOUT ROWID
        """)

        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_session_bindings (
            manifest_sha256 TEXT PRIMARY KEY NOT NULL,
            session_id TEXT NOT NULL CHECK(length(session_id) > 0),
            capture_id TEXT NOT NULL,
            source_snapshot_fingerprint TEXT NOT NULL,
            bound_manifest_bytes BLOB NOT NULL,
            bound_at TEXT NOT NULL,
            project_root_snapshot TEXT,
            remote_eligibility TEXT NOT NULL DEFAULT 'unknown' CHECK(
                remote_eligibility IN ('unknown', 'eligible', 'excluded')
                AND (remote_eligibility != 'unknown' OR project_root_snapshot IS NULL)
                AND (remote_eligibility != 'eligible' OR project_root_snapshot IS NOT NULL)
            ),
            FOREIGN KEY(capture_id) REFERENCES archive_captures(capture_id) ON DELETE RESTRICT
        ) WITHOUT ROWID
        """)
        if try !hasColumn("project_root_snapshot", in: "archive_session_bindings", db: db) {
            try db.execute(sql: """
            ALTER TABLE archive_session_bindings
            ADD COLUMN project_root_snapshot TEXT
            """)
        }
        if try !hasColumn("remote_eligibility", in: "archive_session_bindings", db: db) {
            try db.execute(sql: """
            ALTER TABLE archive_session_bindings
            ADD COLUMN remote_eligibility TEXT NOT NULL DEFAULT 'unknown' CHECK(
                remote_eligibility IN ('unknown', 'eligible', 'excluded')
                AND (remote_eligibility != 'unknown' OR project_root_snapshot IS NULL)
                AND (remote_eligibility != 'eligible' OR project_root_snapshot IS NOT NULL)
            )
            """)
        }
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS archive_session_bindings_session_bound
        ON archive_session_bindings(session_id, bound_at DESC)
        """)
        try db.execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS archive_session_bindings_capture_unique
        ON archive_session_bindings(capture_id)
        """)
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS archive_session_bindings_remote_eligible
        ON archive_session_bindings(manifest_sha256)
        WHERE remote_eligibility = 'eligible'
        """)

        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_replica_receipts (
            manifest_sha256 TEXT NOT NULL,
            capture_id TEXT NOT NULL,
            replica_id TEXT NOT NULL CHECK(length(replica_id) > 0),
            state TEXT NOT NULL CHECK(state IN (
                'pending',
                'uploadingObjects',
                'uploadingManifest',
                'requestingReceipt',
                'verifyingReceipt',
                'verified',
                'retryWait',
                'quarantined'
            )),
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
            next_retry_at TEXT,
            last_error TEXT,
            receipt_bytes BLOB,
            receipt_sha256 TEXT,
            verified_at TEXT,
            updated_at TEXT NOT NULL,
            claim_generation INTEGER NOT NULL DEFAULT 0 CHECK(claim_generation >= 0),
            PRIMARY KEY(manifest_sha256, replica_id),
            FOREIGN KEY(manifest_sha256)
                REFERENCES archive_session_bindings(manifest_sha256) ON DELETE RESTRICT,
            FOREIGN KEY(capture_id) REFERENCES archive_captures(capture_id) ON DELETE RESTRICT,
            CHECK(
                (receipt_bytes IS NULL AND receipt_sha256 IS NULL AND verified_at IS NULL)
                OR
                (receipt_bytes IS NOT NULL AND receipt_sha256 IS NOT NULL AND verified_at IS NOT NULL)
            ),
            CHECK(state != 'verified' OR receipt_bytes IS NOT NULL)
        ) WITHOUT ROWID
        """)
        if try !hasColumn("claim_generation", in: "archive_replica_receipts", db: db) {
            try db.execute(sql: """
            ALTER TABLE archive_replica_receipts
            ADD COLUMN claim_generation INTEGER NOT NULL DEFAULT 0
            CHECK(claim_generation >= 0)
            """)
        }
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS archive_replica_receipts_pending
        ON archive_replica_receipts(state, next_retry_at, updated_at)
        """)

        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_local_objects (
            object_sha256 TEXT PRIMARY KEY NOT NULL,
            raw_byte_count INTEGER NOT NULL CHECK(raw_byte_count > 0),
            residency TEXT NOT NULL CHECK(residency IN ('resident', 'evicted')),
            updated_at TEXT NOT NULL
        ) WITHOUT ROWID
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_manifest_objects (
            manifest_sha256 TEXT NOT NULL,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            object_sha256 TEXT NOT NULL,
            raw_byte_count INTEGER NOT NULL CHECK(raw_byte_count > 0),
            PRIMARY KEY(manifest_sha256, ordinal),
            FOREIGN KEY(manifest_sha256)
                REFERENCES archive_session_bindings(manifest_sha256) ON DELETE RESTRICT,
            FOREIGN KEY(object_sha256)
                REFERENCES archive_local_objects(object_sha256) ON DELETE RESTRICT
        ) WITHOUT ROWID
        """)
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS archive_manifest_objects_by_object
        ON archive_manifest_objects(object_sha256, manifest_sha256)
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_recovery_leases (
            replica_id TEXT PRIMARY KEY NOT NULL CHECK(replica_id IN ('hq', 'm1')),
            manifest_sha256 TEXT NOT NULL,
            verified_at TEXT NOT NULL,
            verified_bytes INTEGER NOT NULL CHECK(verified_bytes >= 0),
            result TEXT NOT NULL CHECK(result = 'verified'),
            error TEXT,
            CHECK(error IS NULL),
            FOREIGN KEY(manifest_sha256)
                REFERENCES archive_session_bindings(manifest_sha256) ON DELETE RESTRICT
        ) WITHOUT ROWID
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS archive_reclamation_intents (
            manifest_sha256 TEXT PRIMARY KEY NOT NULL,
            capture_id TEXT NOT NULL,
            session_id TEXT NOT NULL CHECK(length(session_id) > 0),
            locator TEXT NOT NULL CHECK(length(locator) > 0),
            phase TEXT NOT NULL CHECK(phase IN (
                'eligible', 'quarantinePlanned', 'sourceQuarantined',
                'sourceDeletePlanned', 'sourceDeleted', 'localContentEvicted', 'paused'
            )),
            quarantine_path TEXT,
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
            released_source_bytes INTEGER NOT NULL DEFAULT 0 CHECK(released_source_bytes >= 0),
            released_cas_bytes INTEGER NOT NULL DEFAULT 0 CHECK(released_cas_bytes >= 0),
            last_error TEXT,
            claim_generation INTEGER NOT NULL DEFAULT 0 CHECK(claim_generation >= 0),
            updated_at TEXT NOT NULL,
            FOREIGN KEY(manifest_sha256)
                REFERENCES archive_session_bindings(manifest_sha256) ON DELETE RESTRICT,
            FOREIGN KEY(capture_id) REFERENCES archive_captures(capture_id) ON DELETE RESTRICT,
            CHECK(
                quarantine_path IS NULL OR length(quarantine_path) > 0
            ),
            CHECK(
                (phase IN ('quarantinePlanned', 'sourceQuarantined', 'sourceDeletePlanned')
                    AND quarantine_path IS NOT NULL)
                OR (phase NOT IN ('quarantinePlanned', 'sourceQuarantined', 'sourceDeletePlanned'))
            )
        ) WITHOUT ROWID
        """)
        let intentTableSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'archive_reclamation_intents'"
        ) ?? ""
        if !intentTableSQL.contains("sourceDeletePlanned") {
            try db.execute(sql: """
            CREATE TABLE archive_reclamation_intents_v4 (
                manifest_sha256 TEXT PRIMARY KEY NOT NULL,
                capture_id TEXT NOT NULL,
                session_id TEXT NOT NULL CHECK(length(session_id) > 0),
                locator TEXT NOT NULL CHECK(length(locator) > 0),
                phase TEXT NOT NULL CHECK(phase IN (
                    'eligible', 'quarantinePlanned', 'sourceQuarantined',
                    'sourceDeletePlanned', 'sourceDeleted', 'localContentEvicted', 'paused'
                )),
                quarantine_path TEXT,
                attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
                released_source_bytes INTEGER NOT NULL DEFAULT 0 CHECK(released_source_bytes >= 0),
                released_cas_bytes INTEGER NOT NULL DEFAULT 0 CHECK(released_cas_bytes >= 0),
                last_error TEXT,
                claim_generation INTEGER NOT NULL DEFAULT 0 CHECK(claim_generation >= 0),
                updated_at TEXT NOT NULL,
                FOREIGN KEY(manifest_sha256)
                    REFERENCES archive_session_bindings(manifest_sha256) ON DELETE RESTRICT,
                FOREIGN KEY(capture_id) REFERENCES archive_captures(capture_id) ON DELETE RESTRICT,
                CHECK(quarantine_path IS NULL OR length(quarantine_path) > 0),
                CHECK(
                    (phase IN ('quarantinePlanned', 'sourceQuarantined', 'sourceDeletePlanned')
                        AND quarantine_path IS NOT NULL)
                    OR (phase NOT IN ('quarantinePlanned', 'sourceQuarantined', 'sourceDeletePlanned'))
                )
            ) WITHOUT ROWID
            """)
            try db.execute(sql: """
            INSERT INTO archive_reclamation_intents_v4
            SELECT * FROM archive_reclamation_intents
            """)
            try db.execute(sql: "DROP TABLE archive_reclamation_intents")
            try db.execute(sql: "ALTER TABLE archive_reclamation_intents_v4 RENAME TO archive_reclamation_intents")
        }
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS archive_reclamation_intents_by_phase
        ON archive_reclamation_intents(phase, updated_at, manifest_sha256)
        """)

        let bindings = try Row.fetchAll(
            db,
            sql: "SELECT manifest_sha256, bound_manifest_bytes, bound_at FROM archive_session_bindings"
        )
        for row in bindings {
            let manifestSHA256: String = row["manifest_sha256"]
            let bytes: Data = row["bound_manifest_bytes"]
            let updatedAt: String = row["bound_at"]
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
            guard ArchiveV2Hash.sha256(bytes) == manifestSHA256 else {
                throw ArchiveCatalogError.bindingConflict(manifestSHA256: manifestSHA256)
            }
            for chunk in manifest.chunks {
                try db.execute(
                    sql: """
                    INSERT INTO archive_local_objects(
                        object_sha256, raw_byte_count, residency, updated_at
                    ) VALUES (?, ?, 'resident', ?)
                    ON CONFLICT(object_sha256) DO UPDATE SET
                        residency = 'resident',
                        updated_at = excluded.updated_at
                    WHERE archive_local_objects.raw_byte_count = excluded.raw_byte_count
                    """,
                    arguments: [chunk.rawSHA256, chunk.rawByteCount, updatedAt]
                )
                guard try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM archive_local_objects WHERE object_sha256 = ? AND raw_byte_count = ?",
                    arguments: [chunk.rawSHA256, chunk.rawByteCount]
                ) == 1 else {
                    throw ArchiveCatalogError.boundManifestMismatch(field: "chunks.rawByteCount")
                }
                try db.execute(
                    sql: """
                    INSERT INTO archive_manifest_objects(
                        manifest_sha256, ordinal, object_sha256, raw_byte_count
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(manifest_sha256, ordinal) DO UPDATE SET
                        object_sha256 = excluded.object_sha256,
                        raw_byte_count = excluded.raw_byte_count
                    WHERE archive_manifest_objects.object_sha256 = excluded.object_sha256
                      AND archive_manifest_objects.raw_byte_count = excluded.raw_byte_count
                    """,
                    arguments: [manifestSHA256, chunk.ordinal, chunk.rawSHA256, chunk.rawByteCount]
                )
                guard try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM archive_manifest_objects
                    WHERE manifest_sha256 = ? AND ordinal = ?
                      AND object_sha256 = ? AND raw_byte_count = ?
                    """,
                    arguments: [manifestSHA256, chunk.ordinal, chunk.rawSHA256, chunk.rawByteCount]
                ) == 1 else {
                    throw ArchiveCatalogError.boundManifestMismatch(field: "chunks.reference")
                }
            }
        }

        try db.execute(
            sql: """
            INSERT INTO archive_metadata(key, value) VALUES ('schema_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [currentSchemaVersion]
        )
        try db.execute(
            sql: """
            INSERT INTO archive_metadata(key, value) VALUES ('machine_id', ?)
            ON CONFLICT(key) DO NOTHING
            """,
            arguments: [machineID]
        )
    }

    private static func hasColumn(
        _ column: String,
        in table: String,
        db: Database
    ) throws -> Bool {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").contains { row in
            let name: String = row["name"]
            return name == column
        }
    }
}

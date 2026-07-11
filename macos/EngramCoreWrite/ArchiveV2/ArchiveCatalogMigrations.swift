import GRDB

enum ArchiveCatalogMigrations {
    static let currentSchemaVersion = "2"

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

import Darwin
import Foundation
import SQLite3

/// Metadata discovery and private database custody; neither authorizes an upload.
enum CollectorCursorSource {
    enum DiscoveryError: Error {
        case exceededBudget
        case ambiguousSession
        case sourceChanged
    }

    struct MetadataBudget {
        var maximumSourceBytes: Int64 = 16 * 1024 * 1024
        var maximumMetadataBytes: Int = 1024 * 1024
        var maximumSQLiteSteps: Int64 = 1_000_000
        var maximumLeaseMilliseconds: Int = 5_000
    }

    struct CapturedStoreTestHooks {
        var beforeSQLiteOpen: ((URL) throws -> Void)?
        var beforeMetadataQuery: (() throws -> Void)?
    }

    static func readCapturedStoreMetadata(
        databaseBytes: Data, walBytes: Data?, stagingParent: URL,
        budget: MetadataBudget = .init(), testHooks: CapturedStoreTestHooks = .init()
    ) throws -> String? {
        try Task.checkCancellation()
        guard budget.maximumSourceBytes > 0, budget.maximumMetadataBytes > 0,
              budget.maximumSQLiteSteps > 0, budget.maximumLeaseMilliseconds > 0 else {
            throw CollectorSQLiteSnapshotError.exceededBudget
        }
        let clock = try CursorMetadataReadBudget(budget)
        return try CollectorSQLiteSnapshotLease.withCapturedPair(
            databaseBytes: databaseBytes, walBytes: walBytes, databaseName: "store.db", stagingParent: stagingParent,
            budget: .init(maximumSnapshotByteCount: budget.maximumSourceBytes,
                maximumCopyByteCount: budget.maximumSourceBytes, maximumLeaseMilliseconds: budget.maximumLeaseMilliseconds),
            testHooks: .init(beforeSnapshotUse: testHooks.beforeSQLiteOpen)
        ) { url, validatePair in
            try clock.check()
            var opened: OpaquePointer?
            // A sealed no-WAL image needs no recovery or generated sidecars.
            // With WAL, SQLite builds its WAL index only in owned private staging.
            let path = walBytes == nil ? url.absoluteString + "?immutable=1" : url.path
            let flags = walBytes == nil ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW
                : SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW
            let result = sqlite3_open_v2(path, &opened, flags, nil)
            guard result == SQLITE_OK, let db = opened else {
                if let opened { sqlite3_close(opened) }
                throw CollectorSQLiteSnapshotError.unavailable
            }
            defer {
                sqlite3_set_authorizer(db, nil, nil)
                sqlite3_progress_handler(db, 0, nil, nil)
                sqlite3_close(db)
            }
            sqlite3_busy_timeout(db, 0)
            _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(clamping: budget.maximumSourceBytes))
            _ = sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 4096)
            sqlite3_progress_handler(db, 1, { context in
                guard let context else { return 1 }
                return Unmanaged<CursorMetadataReadBudget>.fromOpaque(context).takeUnretainedValue().tick()
            }, Unmanaged.passUnretained(clock).toOpaque())
            let settings = sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA temp_store=MEMORY; PRAGMA trusted_schema=OFF", nil, nil, nil)
            guard settings == SQLITE_OK else { try clock.fail(settings) }
            func prepare(_ sql: String) throws -> OpaquePointer {
                try clock.check()
                var statement: OpaquePointer?
                let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
                guard status == SQLITE_OK, let statement else {
                    if let statement { sqlite3_finalize(statement) }
                    try clock.fail(status)
                }
                return statement
            }
            func step(_ statement: OpaquePointer) throws -> Int32 {
                try clock.check()
                let status = sqlite3_step(statement)
                guard status == SQLITE_ROW || status == SQLITE_DONE else { try clock.fail(status) }
                return status
            }
            func text(_ statement: OpaquePointer, _ column: Int32, maximum: Int) throws -> String? {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
                guard let pointer = sqlite3_column_text(statement, column) else { throw CollectorSQLiteSnapshotError.unavailable }
                let length = Int(sqlite3_column_bytes(statement, column))
                guard length <= maximum else { throw CollectorSQLiteSnapshotError.exceededBudget }
                let bytes = Data(bytes: pointer, count: length)
                guard !bytes.contains(0), let value = String(data: bytes, encoding: .utf8) else {
                    throw CollectorSQLiteSnapshotError.unsafePath
                }
                return value
            }
            // SQLite's own table classification avoids trusting SQL spelling
            // (comments/whitespace can disguise CREATE VIRTUAL TABLE text).
            let schema = try prepare("PRAGMA main.table_list('meta')")
            defer { sqlite3_finalize(schema) }
            guard try step(schema) == SQLITE_ROW,
                  try text(schema, 1, maximum: 128) == "meta",
                  try text(schema, 2, maximum: 128) == "table",
                  try step(schema) == SQLITE_DONE else { throw CollectorSQLiteSnapshotError.unsafePath }
            guard sqlite3_set_authorizer(db, { _, operation, first, second, _, _ in
                if operation == SQLITE_SELECT { return SQLITE_OK }
                if operation == SQLITE_READ, let first, let second,
                   String(cString: first) == "meta", ["key", "value"].contains(String(cString: second)) { return SQLITE_OK }
                return SQLITE_DENY
            }, nil) == SQLITE_OK else { throw CollectorSQLiteSnapshotError.unavailable }
            try testHooks.beforeMetadataQuery?()
            try clock.check()
            try validatePair()
            let statement = try prepare("SELECT value FROM meta WHERE key = '0' LIMIT 2")
            defer { sqlite3_finalize(statement) }
            var found = false
            var value: String?
            while try step(statement) == SQLITE_ROW {
                guard !found else { throw CollectorSQLiteSnapshotError.unsafePath }
                found = true
                value = try text(statement, 0, maximum: budget.maximumMetadataBytes)
            }
            try clock.check()
            try validatePair()
            return value
        }
    }

    struct ModernSession: Equatable {
        let nativeSessionID: String
        let storeRelativePath: String?
        let transcriptRelativePath: String?
        let present: [CollectorDependencySnapshot.PresentMember]
        let absentRelativePaths: [String]
    }

    struct CapturedMember: Equatable {
        let relativePath: String
        let generation: ArchiveSourceGeneration
        let bytes: Data
    }

    struct ModernCapture: Equatable {
        let rootPath: String
        let session: ModernSession
        let files: [CapturedMember]
    }

    struct CaptureTestHooks {
        var snapshot: CollectorSQLiteSnapshotLease.TestHooks = .init()
        var afterFileRead: ((String) throws -> Void)?
        var beforeFinalValidation: (() throws -> Void)?
        var uptimeNanoseconds: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    /// Byte-exact modern main/WAL plus JSONL/meta, not a reconstructed DB image.
    /// Source SHM/journal are safety observations and never become replay members.
    static func captureModern(
        rootPath: String, session: ModernSession, stagingParent: URL,
        maximumByteCount: Int64 = 16 * 1024 * 1024, maximumDirectoryEntries: Int = 4096,
        budget: CollectorSQLiteSnapshotLease.Budget = .init(), testHooks: CaptureTestHooks = .init()
    ) throws -> ModernCapture {
        guard maximumByteCount >= 0, maximumDirectoryEntries > 0,
              budget.maximumLeaseMilliseconds >= 0, budget.maximumCopyByteCount >= 0,
              budget.maximumSnapshotByteCount >= 0 else { throw CollectorSQLiteSnapshotError.exceededBudget }
        let duration = UInt64(budget.maximumLeaseMilliseconds).multipliedReportingOverflow(by: 1_000_000)
        let end = testHooks.uptimeNanoseconds().addingReportingOverflow(duration.partialValue)
        guard !duration.overflow, !end.overflow else { throw CollectorSQLiteSnapshotError.exceededBudget }
        func checkBudget() throws {
            try Task.checkCancellation()
            guard testHooks.uptimeNanoseconds() <= end.partialValue else {
                throw CollectorSQLiteSnapshotError.exceededBudget
            }
        }
        try checkBudget()
        let root = URL(fileURLWithPath: rootPath)
        try CollectorSQLiteSnapshotLease.validateStagingParent(root: root, stagingParent: stagingParent)
        let scanner = Scanner(rootPath: rootPath, budget: maximumDirectoryEntries, checkBudget: checkBudget)
        let first = try scanner.scan()
        guard let observed = first.sessions.first(where: { $0.nativeSessionID.utf8.elementsEqual(session.nativeSessionID.utf8) }),
              sameSession(observed, session) else { throw DiscoveryError.sourceChanged }
        var paths = Set<Data>()
        if let store = session.storeRelativePath {
            paths.insert(Data(store.utf8))
            paths.insert(Data((store + "-wal").utf8))
            paths.insert(Data((store.split(separator: "/").dropLast().joined(separator: "/") + "/meta.json").utf8))
        }
        if let transcript = session.transcriptRelativePath { paths.insert(Data(transcript.utf8)) }
        let members = session.present.filter { paths.contains(Data($0.relativePath.utf8)) }
        var total: Int64 = 0
        for member in members {
            let sum = total.addingReportingOverflow(member.generation.size)
            guard !sum.overflow, sum.partialValue <= maximumByteCount else { throw CollectorSQLiteSnapshotError.exceededBudget }
            total = sum.partialValue
        }
        guard !members.isEmpty else { throw DiscoveryError.sourceChanged }

        func collect(_ snapshot: CollectorSQLiteSnapshotLease.Snapshot?) throws -> ModernCapture {
            try checkBudget()
            if let snapshot, let store = session.storeRelativePath {
                guard snapshot.databaseGeneration == session.present.first(where: { $0.relativePath.utf8.elementsEqual(store.utf8) })?.generation,
                      snapshot.walGeneration == session.present.first(where: { $0.relativePath.utf8.elementsEqual((store + "-wal").utf8) })?.generation else {
                    throw DiscoveryError.sourceChanged
                }
            }
            var files: [CapturedMember] = []
            var remaining = maximumByteCount
            for member in members {
                try checkBudget()
                try snapshot?.validateRawPair()
                let isMain = session.storeRelativePath.map { member.relativePath.utf8.elementsEqual($0.utf8) } ?? false
                let isWAL = session.storeRelativePath.map { member.relativePath.utf8.elementsEqual(($0 + "-wal").utf8) } ?? false
                let url: URL
                if isMain || isWAL {
                    guard let snapshot else { throw DiscoveryError.sourceChanged }
                    url = isMain ? snapshot.privateDatabaseURL : URL(fileURLWithPath: snapshot.privateDatabaseURL.path + "-wal")
                } else { url = root.appendingPathComponent(member.relativePath) }
                let bytes = try readCapturedMember(url: url, expected: isMain || isWAL ? nil : member.generation,
                    expectedSize: member.generation.size, maximumBytes: remaining, checkBudget: checkBudget)
                remaining -= Int64(bytes.count)
                files.append(.init(relativePath: member.relativePath, generation: member.generation, bytes: bytes))
                try testHooks.afterFileRead?(member.relativePath)
                try snapshot?.validateRawPair()
            }
            try testHooks.beforeFinalValidation?()
            try snapshot?.validateRawPair()
            let final = try Scanner(rootPath: rootPath, budget: scanner.remainingEntries, checkBudget: checkBudget).scan()
            try validateSelectedObservation(first, final, session: session)
            try checkBudget()
            return ModernCapture(rootPath: rootPath, session: session, files: files)
        }

        if let store = session.storeRelativePath {
            let parts = store.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "chats", parts[3] == "store.db",
                  parts[2].utf8.elementsEqual(session.nativeSessionID.utf8) else { throw CollectorSQLiteSnapshotError.unsafePath }
            return try CollectorSQLiteSnapshotLease.withSnapshot(
                root: root.appendingPathComponent(parts.dropLast().joined(separator: "/")), databaseName: "store.db",
                stagingParent: stagingParent, budget: budget, testHooks: testHooks.snapshot
            ) { try collect($0) }
        }
        return try collect(nil)
    }

    struct SessionObservation {
        let session: ModernSession
        let generation: ArchiveSourceGeneration
        let snapshot: CollectorDependencySnapshot
    }

    static func capturedDependenciesChanged(rootPath: String, manifest: ArchiveSourceManifest) throws -> Bool {
        guard ArchiveSourceDescriptor.isCursorModernFileSet(manifest),
              let files = manifest.replayLayout.files,
              let absent = manifest.replayLayout.absentRelativePaths else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let components = try CollectorPOSIXDirectoryAccess.components(rootPath)
        let root = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
        defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
        func observed(_ path: String) throws -> ArchiveSourceGeneration? {
            try Task.checkCancellation()
            let parts = path.split(separator: "/").map(String.init)
            var parent = root.descriptor
            var opened: [Int32] = []
            defer { for descriptor in opened.reversed() { CollectorPOSIXDirectoryAccess.close(descriptor) } }
            for part in parts.dropLast() {
                parent = try CollectorPOSIXDirectoryAccess.openComponent(part, parent: parent)
                opened.append(parent)
            }
            return try regularGeneration(parent, parts.last!)
        }
        // Only stat the already captured, bounded dependency list. This hint
        // neither walks directories nor reads source payload/SQLite contents.
        do {
            for file in files where try observed(file.relativePath) != file.generation { return true }
            for path in absent where try observed(path) != nil { return true }
        } catch is CancellationError { throw CancellationError() }
        catch { return true } // Changed/unavailable paths must retain capture retry work.
        let current = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
        defer { CollectorPOSIXDirectoryAccess.close(current.descriptor) }
        return try CollectorPOSIXDirectoryAccess.identity(root.info)
            != CollectorPOSIXDirectoryAccess.identity(current.info)
    }

    static func eventObservationFingerprint(_ session: ModernSession) throws -> String {
        struct FileSet: Encodable {
            let paths: [String]
            let generations: [ArchiveSourceGeneration]
            let absentRelativePaths: [String]
        }
        // Discovery sorts by UTF8 bytes. Preserve that spelling and include
        // dependency-only changes, but exclude SHM/journal safety observations.
        let present = session.present.filter { sessionOwning($0.relativePath) != nil }
        let observation = FileSet(
            paths: present.map(\.relativePath), generations: present.map(\.generation),
            absentRelativePaths: session.absentRelativePaths.filter { sessionOwning($0) != nil }
        )
        return "cursor-files-v1:" + ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(observation))
    }

    static func sessionOwning(_ relative: String) -> String? {
        guard CollectorInventoryStore.isSafeRelativePath(relative) else { return nil }
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ !$0.hasPrefix(".") }) else { return nil }
        if parts.count == 4, parts[0] == "chats",
           ["store.db", "store.db-wal", "meta.json"].contains(parts[3]) { return parts[2] }
        if parts.count == 5, parts[0] == "projects", parts[2] == "agent-transcripts",
           parts[4].utf8.elementsEqual((parts[3] + ".jsonl").utf8) { return parts[3] }
        return nil
    }

    static func observe(rootPath: String, primaryRelative: String) throws -> SessionObservation {
        guard let id = sessionOwning(primaryRelative) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let session = try discoverTargetedModern(rootPath: rootPath, nativeSessionID: id)
        guard session.present.contains(where: { $0.relativePath.utf8.elementsEqual(primaryRelative.utf8) })
                || session.absentRelativePaths.contains(where: { $0.utf8.elementsEqual(primaryRelative.utf8) }),
              let primary = session.transcriptRelativePath ?? session.storeRelativePath else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        var payload = Set<Data>()
        var absenceSlots = Set<Data>()
        if let transcript = session.transcriptRelativePath { payload.insert(Data(transcript.utf8)) }
        if let store = session.storeRelativePath {
            payload.insert(Data(store.utf8))
            let parent = store.split(separator: "/").dropLast().joined(separator: "/")
            for path in [store + "-wal", parent + "/meta.json"] {
                let key = Data(path.utf8)
                payload.insert(key)
                absenceSlots.insert(key)
            }
        }
        let snapshot = CollectorDependencySnapshot(entrypointRelativePath: primary,
            present: session.present.filter { payload.contains(Data($0.relativePath.utf8)) },
            absentRelativePaths: session.absentRelativePaths.filter { absenceSlots.contains(Data($0.utf8)) })
        try requireValidSnapshot(snapshot, entrypoint: primary)
        guard let generation = snapshot.present.first(where: { $0.relativePath.utf8.elementsEqual(primary.utf8) })?.generation else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return .init(session: session, generation: generation, snapshot: snapshot)
    }

    static func requireValidSnapshot(_ snapshot: CollectorDependencySnapshot, entrypoint: String) throws {
        try Task.checkCancellation()
        guard snapshot.geminiProjectContext == nil, snapshot.kimiProjectContext == nil,
              snapshot.entrypointRelativePath.utf8.elementsEqual(entrypoint.utf8),
              (1...4).contains(snapshot.present.count), snapshot.absentRelativePaths.count <= 2 else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        do {
            // Project only shape/generations into the shared closed-layout validator.
            // Placeholder hashes are never persisted or used as captured-byte proof.
            let placeholder = ArchiveV2Hash.sha256(Data())
            var offset: Int64 = 0
            let files = try snapshot.present.map { member in
                let file = try ArchiveFileSetEntry(relativePath: member.relativePath, byteOffset: offset,
                    rawByteCount: member.generation.size, wholeSourceSHA256: placeholder, generation: member.generation)
                let next = offset.addingReportingOverflow(member.generation.size)
                guard !next.overflow else { throw CollectorPublicationWorkerError.invalidCapture }
                offset = next.partialValue
                return file
            }
            let layout = try ArchiveReplayLayout(strategy: .fileSet, relativePaths: files.map(\.relativePath),
                entrypointRelativePath: entrypoint, files: files, absentRelativePaths: snapshot.absentRelativePaths)
            guard ArchiveSourceDescriptor.cursorModernSessionID(layout, locator: "/cursor-reservation/" + entrypoint) != nil else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        } catch {
            throw CollectorPublicationWorkerError.invalidCapture
        }
    }

    static func reservedPathsEqual(_ lhs: CollectorDependencySnapshot?, _ rhs: CollectorDependencySnapshot?) -> Bool {
        lhs.map { Data($0.entrypointRelativePath.utf8) } == rhs.map { Data($0.entrypointRelativePath.utf8) }
            && lhs?.present.map { Data($0.relativePath.utf8) } == rhs?.present.map { Data($0.relativePath.utf8) }
            && lhs?.absentRelativePaths.map { Data($0.utf8) } == rhs?.absentRelativePaths.map { Data($0.utf8) }
    }

    static func matchesReservedSnapshot(_ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest) -> Bool {
        guard (try? requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)) != nil,
              ArchiveSourceDescriptor.isCursorModernFileSet(manifest),
              let files = manifest.replayLayout.files, let absent = manifest.replayLayout.absentRelativePaths,
              let primary = manifest.replayLayout.entrypointRelativePath,
              primary.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8),
              files.count == snapshot.present.count, absent.count == snapshot.absentRelativePaths.count else { return false }
        return zip(files, snapshot.present).allSatisfy { file, member in
            file.relativePath.utf8.elementsEqual(member.relativePath.utf8) && file.generation == member.generation
        } && zip(absent, snapshot.absentRelativePaths).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    static func persistModern(
        _ capture: ModernCapture, machineID: String, cas: ImmutableArchiveCAS, catalog: ArchiveCatalog,
        maximumByteCount: Int64? = nil
    ) throws -> ArchiveCaptureResult {
        guard let primary = capture.session.transcriptRelativePath ?? capture.session.storeRelativePath else {
            throw DiscoveryError.sourceChanged
        }
        var absenceSlots = Set<Data>()
        if let store = capture.session.storeRelativePath {
            absenceSlots.insert(Data((store + "-wal").utf8))
            let parent = store.split(separator: "/").dropLast().joined(separator: "/")
            absenceSlots.insert(Data((parent + "/meta.json").utf8))
        }
        let absent = capture.session.absentRelativePaths.filter { absenceSlots.contains(Data($0.utf8)) }
        return try ExactSourceCapturer.captureCursorModernFileSet(capture.files.map {
            ArchiveCapturedFile(relativePath: $0.relativePath, generation: $0.generation, bytes: $0.bytes)
        }, locator: capture.rootPath + "/" + primary, absentRelativePaths: absent,
            machineID: machineID, cas: cas, catalog: catalog, maximumByteCount: maximumByteCount)
    }

    private static func readCapturedMember(
        url: URL, expected: ArchiveSourceGeneration?, expectedSize: Int64,
        maximumBytes: Int64, checkBudget: () throws -> Void
    ) throws -> Data {
        try checkBudget()
        let parentPath = url.deletingLastPathComponent().path
        let parent = try CollectorPOSIXDirectoryAccess.openAbsolute(components: CollectorPOSIXDirectoryAccess.components(parentPath))
        defer { CollectorPOSIXDirectoryAccess.close(parent.descriptor) }
        let name = url.lastPathComponent
        let descriptor = name.withCString { openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw DiscoveryError.sourceChanged }
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CollectorSQLiteSnapshotError.unsafePath }
        let before = try generation(info)
        guard before.size == expectedSize, expected == nil || before == expected else { throw DiscoveryError.sourceChanged }
        guard expectedSize <= maximumBytes, let capacity = Int(exactly: expectedSize) else { throw CollectorSQLiteSnapshotError.exceededBudget }
        var data = Data()
        data.reserveCapacity(capacity)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < capacity {
            try checkBudget()
            let wanted = min(buffer.count, capacity - data.count)
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, off_t(data.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw DiscoveryError.sourceChanged }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, try generation(after) == before,
              let named = try namedStat(parent.descriptor, name), try generation(named) == before else {
            throw DiscoveryError.sourceChanged
        }
        let current = try CollectorPOSIXDirectoryAccess.openAbsolute(components: CollectorPOSIXDirectoryAccess.components(parentPath))
        defer { CollectorPOSIXDirectoryAccess.close(current.descriptor) }
        guard try CollectorPOSIXDirectoryAccess.identity(current.info) == CollectorPOSIXDirectoryAccess.identity(parent.info) else {
            throw DiscoveryError.sourceChanged
        }
        try checkBudget()
        return data
    }

    /// Seals only the database component. JSONL/meta bytes still need a bound
    /// composite capture before this can become an archive publication.
    static func withModernStoreSnapshot<T>(
        rootPath: String, session: ModernSession, stagingParent: URL,
        budget: CollectorSQLiteSnapshotLease.Budget = .init(),
        maximumDirectoryEntries: Int = 4096,
        testHooks: CollectorSQLiteSnapshotLease.TestHooks = .init(),
        _ body: (CollectorSQLiteSnapshotLease.Snapshot) throws -> T
    ) throws -> T {
        guard maximumDirectoryEntries > 0 else { throw DiscoveryError.exceededBudget }
        guard let store = session.storeRelativePath,
              CollectorInventoryStore.isSafeRelativePath(store) else {
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        let parts = store.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "chats", parts[3] == "store.db",
              parts[2].utf8.elementsEqual(session.nativeSessionID.utf8) else {
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        let root = URL(fileURLWithPath: rootPath)
        try CollectorSQLiteSnapshotLease.validateStagingParent(root: root, stagingParent: stagingParent)
        let scanner = Scanner(rootPath: rootPath, budget: maximumDirectoryEntries)
        let first = try scanner.scan()
        guard let observed = first.sessions.first(where: { $0.nativeSessionID.utf8.elementsEqual(session.nativeSessionID.utf8) }),
              sameSession(observed, session) else { throw DiscoveryError.sourceChanged }
        let storeRoot = root.appendingPathComponent(parts.dropLast().joined(separator: "/"))
        return try CollectorSQLiteSnapshotLease.withSnapshot(
            root: storeRoot, databaseName: "store.db", stagingParent: stagingParent,
            budget: budget, testHooks: testHooks
        ) { snapshot in
            guard snapshot.databaseGeneration == session.present.first(where: { $0.relativePath.utf8.elementsEqual(store.utf8) })?.generation,
                  snapshot.walGeneration == session.present.first(where: { $0.relativePath.utf8.elementsEqual((store + "-wal").utf8) })?.generation else {
                throw DiscoveryError.sourceChanged
            }
            let final = try Scanner(rootPath: rootPath, budget: scanner.remainingEntries).scan()
            try validateSelectedObservation(first, final, session: session)
            return try body(snapshot)
        }
    }

    private static func sameSession(_ lhs: ModernSession, _ rhs: ModernSession) -> Bool {
        guard lhs == rhs else { return false }
        let left = [lhs.nativeSessionID, lhs.storeRelativePath ?? "", lhs.transcriptRelativePath ?? ""]
            + lhs.present.map(\.relativePath) + lhs.absentRelativePaths
        let right = [rhs.nativeSessionID, rhs.storeRelativePath ?? "", rhs.transcriptRelativePath ?? ""]
            + rhs.present.map(\.relativePath) + rhs.absentRelativePaths
        return zip(left, right).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    static func discoverModern(
        rootPath: String, maximumDirectoryEntries: Int = 4096,
        beforeFinalValidation: (() throws -> Void)? = nil
    ) throws -> [ModernSession] {
        guard maximumDirectoryEntries > 0 else { throw DiscoveryError.exceededBudget }
        let scanner = Scanner(rootPath: rootPath, budget: maximumDirectoryEntries)
        let first = try scanner.scan()
        try beforeFinalValidation?()
        let second = try Scanner(rootPath: rootPath, budget: scanner.remainingEntries).scan()
        guard first == second else { throw DiscoveryError.sourceChanged }
        return first.sessions
    }

    /// Two-pass lookup of one native ID across every allowed store and
    /// transcript parent. Unrelated session directories are not listed or
    /// payload-statted; a second store or transcript for this ID still refuses.
    private static func discoverTargetedModern(
        rootPath: String, nativeSessionID: String, maximumDirectoryEntries: Int = 4096
    ) throws -> ModernSession {
        guard maximumDirectoryEntries > 0 else { throw DiscoveryError.exceededBudget }
        let scanner = Scanner(rootPath: rootPath, budget: maximumDirectoryEntries, targetSessionID: nativeSessionID)
        let first = try scanner.scan()
        let second = try Scanner(rootPath: rootPath, budget: scanner.remainingEntries, targetSessionID: nativeSessionID).scan()
        guard first == second else { throw DiscoveryError.sourceChanged }
        guard let session = first.sessions.first(where: { $0.nativeSessionID.utf8.elementsEqual(nativeSessionID.utf8) }) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return session
    }

    private struct Observation: Equatable {
        let sessions: [ModernSession]
        // Data keys retain the filesystem spelling, including Unicode normalization.
        let directories: [Data: CollectorPOSIXDirectoryIdentity]
    }

    private static func validateSelectedObservation(
        _ first: Observation, _ final: Observation, session: ModernSession
    ) throws {
    guard let current = final.sessions.first(where: { $0.nativeSessionID.utf8.elementsEqual(session.nativeSessionID.utf8) }),
          sameSession(current, session) else { throw DiscoveryError.sourceChanged }
    // Bind the configured root and every selected dependency's directory
    // chain; unrelated sessions need not keep the same generation.
    for path in session.present.map(\.relativePath) + session.absentRelativePaths {
        let components = path.split(separator: "/")
        for count in 0..<components.count {
            let key = Data(components.prefix(count).joined(separator: "/").utf8)
            guard let identity = first.directories[key], identity == final.directories[key] else {
                throw DiscoveryError.sourceChanged
            }
        }
    }
    }

    private struct Candidate {
        let id: String
        var store: String?
        var transcript: String?
        var present: [CollectorDependencySnapshot.PresentMember] = []
        var absent: [String] = []
    }

    private final class Scanner {
        let rootPath: String
        let targetSessionID: String?
        var remainingEntries: Int
        var directories: [Data: CollectorPOSIXDirectoryIdentity] = [:]
        var candidates: [Data: Candidate] = [:]

        let checkBudget: () throws -> Void

        init(
            rootPath: String, budget: Int, targetSessionID: String? = nil,
            checkBudget: @escaping () throws -> Void = { try Task.checkCancellation() }
        ) {
            self.checkBudget = checkBudget
            self.rootPath = rootPath
            self.targetSessionID = targetSessionID
            remainingEntries = budget
        }

        func scan() throws -> Observation {
            try checkBudget()
            let components = try CollectorPOSIXDirectoryAccess.components(rootPath)
            let root = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
            defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
            try walk(root.descriptor, parts: [])
            // A detached root descriptor cannot vouch for the configured route.
            let current = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
            defer { CollectorPOSIXDirectoryAccess.close(current.descriptor) }
            guard try CollectorPOSIXDirectoryAccess.identity(root.info)
                == CollectorPOSIXDirectoryAccess.identity(current.info) else {
                throw DiscoveryError.sourceChanged
            }
            let sessions = candidates.values.compactMap { candidate -> ModernSession? in
                guard candidate.store != nil || candidate.transcript != nil else { return nil }
                return ModernSession(
                    nativeSessionID: candidate.id, storeRelativePath: candidate.store,
                    transcriptRelativePath: candidate.transcript,
                    present: candidate.present.sorted { byteOrder($0.relativePath, $1.relativePath) },
                    absentRelativePaths: candidate.absent.sorted(by: byteOrder)
                )
            }.sorted { byteOrder($0.nativeSessionID, $1.nativeSessionID) }
            return Observation(sessions: sessions, directories: directories)
        }

        func walk(_ descriptor: Int32, parts: [String]) throws {
            try checkBudget()
            let before = try CollectorPOSIXDirectoryAccess.directoryStat(descriptor)
            let relative = parts.joined(separator: "/")
            directories[Data(relative.utf8)] = try CollectorPOSIXDirectoryAccess.identity(before)
            let isStore = parts.count == 3 && parts.first == "chats"
            let isTranscript = parts.count == 4 && parts.first == "projects"
            if isStore || isTranscript {
                // Full discovery still enumerates the session directory so
                // unrelated noise counts against the shared entry budget.
                if targetSessionID == nil { _ = try entryNames(descriptor) }
                try observeSession(descriptor, parts: parts, isStore: isStore)
            } else if let target = targetSessionID, isSessionParent(parts) {
                try visitTargetedSession(descriptor, parts: parts, name: target)
            } else {
                for name in try entryNames(descriptor) {
                    try checkBudget()
                    let fixedDirectory: Bool
                    switch parts.count {
                    case 0:
                        guard name == "chats" || name == "projects" else { continue }
                        fixedDirectory = true
                    case 2 where parts.first == "projects":
                        guard name == "agent-transcripts" else { continue }
                        fixedDirectory = true
                    default:
                        fixedDirectory = false
                    }
                    try visitChild(descriptor, parts: parts, name: name, fixedDirectory: fixedDirectory)
                }
            }
            // Refuse mutation during a single directory walk. Between the two
            // observations only identities and recognized dependencies matter:
            // an unrelated scratch file is not a session input.
            guard try generation(before)
                == generation(CollectorPOSIXDirectoryAccess.directoryStat(descriptor)) else {
                throw DiscoveryError.sourceChanged
            }
        }

        func isSessionParent(_ parts: [String]) -> Bool {
            (parts.count == 2 && parts.first == "chats")
                || (parts.count == 3 && parts.first == "projects" && parts.last == "agent-transcripts")
        }

        func visitTargetedSession(_ descriptor: Int32, parts: [String], name: String) throws {
            try checkBudget()
            // Enumerate actual UTF-8 dirents. Direct openat(requested ID) can
            // land on a case/normalization-equivalent child and mis-attribute it.
            for entry in try entryNames(descriptor) {
                try checkBudget()
                guard entry.utf8.elementsEqual(name.utf8) else { continue }
                try visitChild(descriptor, parts: parts, name: entry, fixedDirectory: false)
            }
        }

        func visitChild(
            _ descriptor: Int32, parts: [String], name: String, fixedDirectory: Bool
        ) throws {
            if !fixedDirectory && name.hasPrefix(".") { return }
            guard let info = try namedStat(descriptor, name) else { throw DiscoveryError.sourceChanged }
            if !fixedDirectory && info.st_flags & UInt32(UF_HIDDEN) != 0 { return }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK {
                if fixedDirectory { throw CollectorPOSIXEnumerationError.unsafePath }
                // Native directChildren skips links; do not follow a
                // workspace/session child merely to determine its type.
                return
            }
            guard kind == S_IFDIR else {
                if fixedDirectory { throw CollectorPOSIXEnumerationError.unsafePath }
                return
            }
            let childParts = parts + [name]
            try validateLength(childParts)
            let child = try CollectorPOSIXDirectoryAccess.openComponent(name, parent: descriptor)
            defer { CollectorPOSIXDirectoryAccess.close(child) }
            guard try CollectorPOSIXDirectoryAccess.identity(info)
                == CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(child)) else {
                throw DiscoveryError.sourceChanged
            }
            try walk(child, parts: childParts)
            guard let named = try namedStat(descriptor, name),
                  named.st_mode & S_IFMT == S_IFDIR,
                  try CollectorPOSIXDirectoryAccess.identity(named)
                    == CollectorPOSIXDirectoryAccess.identity(info) else {
                throw DiscoveryError.sourceChanged
            }
        }

        func observeSession(_ descriptor: Int32, parts: [String], isStore: Bool) throws {
            try checkBudget()
            guard let id = parts.last else { throw CollectorPOSIXEnumerationError.unsafePath }
            let key = Data(id.utf8)
            var candidate = candidates[key] ?? Candidate(id: id)
            let name = isStore ? "store.db" : id + ".jsonl"
            let primary = (parts + [name]).joined(separator: "/")
            try validateLength(parts + [name])
            if let observed = try regularGeneration(descriptor, name) {
                if isStore {
                    guard candidate.store == nil else { throw DiscoveryError.ambiguousSession }
                    candidate.store = primary
                } else {
                    guard candidate.transcript == nil else { throw DiscoveryError.ambiguousSession }
                    candidate.transcript = primary
                }
                candidate.present.append(.init(relativePath: primary, generation: observed))
                if isStore {
                    // SHM/journal are safety observations, not replay payloads.
                    // Snapshot admission must independently decide whether a
                    // coherent private SQLite lease is possible.
                    for sidecar in ["store.db-wal", "store.db-shm", "store.db-journal", "meta.json"] {
                        try validateLength(parts + [sidecar])
                        let path = (parts + [sidecar]).joined(separator: "/")
                        if let observed = try regularGeneration(descriptor, sidecar) {
                            candidate.present.append(.init(relativePath: path, generation: observed))
                        } else {
                            candidate.absent.append(path)
                        }
                    }
                }
            } else {
                // Only a known directory can establish a missing primary path.
                // Its metadata is not a native dependency without store.db.
                candidate.absent.append(primary)
            }
            candidates[key] = candidate
        }

        func validateLength(_ parts: [String]) throws {
            guard rootPath.utf8.count + 1 + parts.joined(separator: "/").utf8.count
                <= CollectorPOSIXRootEnumerator.maximumPathBytes else {
                throw CollectorPOSIXEnumerationError.unsafePath
            }
        }

        func entryNames(_ descriptor: Int32) throws -> [String] {
            let copied = try duplicateDirectoryDescriptor(descriptor)
            guard let stream = fdopendir(copied) else {
                _ = Darwin.close(copied)
                throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno)
            }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                try checkBudget()
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw CollectorPOSIXEnumerationError.io(.readDirectory, errno) }
                    break
                }
                var value = entry.pointee
                let count = Int(value.d_namlen)
                let name: String = try withUnsafeBytes(of: &value.d_name) { bytes in
                    guard count > 0, count < bytes.count, bytes[count] == 0 else {
                        throw CollectorPOSIXEnumerationError.invalidEntryName
                    }
                    return try CollectorPOSIXRootEnumerator.decodeEntryName(Data(bytes.prefix(count)))
                }
                if name == "." || name == ".." { continue }
                guard remainingEntries > 0 else { throw DiscoveryError.exceededBudget }
                remainingEntries -= 1
                names.append(name)
            }
            return names.sorted(by: byteOrder)
        }
    }

    private static func byteOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    static func duplicateDirectoryDescriptor(_ descriptor: Int32) throws -> Int32 {
        let copied = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard copied >= 0 else { throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno) }
        return copied
    }

    private static func namedStat(_ descriptor: Int32, _ name: String) throws -> stat? {
        try Task.checkCancellation()
        var info = stat()
        guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT { return nil }
            throw CollectorPOSIXEnumerationError.io(.statEntry, errno)
        }
        return info
    }

    private static func regularGeneration(_ descriptor: Int32, _ name: String) throws -> ArchiveSourceGeneration? {
        guard let info = try namedStat(descriptor, name) else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CollectorPOSIXEnumerationError.unsafePath }
        return try generation(info)
    }

    private static func generation(_ info: stat) throws -> ArchiveSourceGeneration {
        func nanos(_ time: timespec) throws -> Int64 {
            let seconds = Int64(time.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let result = seconds.partialValue.addingReportingOverflow(Int64(time.tv_nsec))
            guard !seconds.overflow, !result.overflow else {
                throw CollectorPOSIXEnumerationError.io(.statEntry, EOVERFLOW)
            }
            return result.partialValue
        }
        guard let inode = Int64(exactly: info.st_ino) else {
            throw CollectorPOSIXEnumerationError.io(.statEntry, EOVERFLOW)
        }
        return try ArchiveSourceGeneration(
            device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
            mtimeNs: nanos(info.st_mtimespec), ctimeNs: nanos(info.st_ctimespec), mode: Int64(info.st_mode)
        )
    }
}

/// One budget spans private materialization, schema inspection and key-0 query.
private final class CursorMetadataReadBudget {
    let deadline: UInt64
    var remainingSteps: Int64
    var exhausted = false

    init(_ budget: CollectorCursorSource.MetadataBudget) throws {
        let duration = UInt64(budget.maximumLeaseMilliseconds).multipliedReportingOverflow(by: 1_000_000)
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW).addingReportingOverflow(duration.partialValue)
        guard !duration.overflow, !end.overflow else { throw CollectorSQLiteSnapshotError.exceededBudget }
        deadline = end.partialValue
        remainingSteps = budget.maximumSQLiteSteps
    }

    func check() throws {
        try Task.checkCancellation()
        guard !exhausted, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) <= deadline else {
            throw CollectorSQLiteSnapshotError.exceededBudget
        }
    }

    func tick() -> Int32 {
        do {
            try check()
            guard remainingSteps > 0 else { exhausted = true; return 1 }
            remainingSteps -= 1
            return 0
        } catch { return 1 }
    }

    func fail(_ status: Int32) throws -> Never {
        try check()
        if status == SQLITE_TOOBIG { throw CollectorSQLiteSnapshotError.exceededBudget }
        if status == SQLITE_AUTH { throw CollectorSQLiteSnapshotError.unsafePath }
        throw CollectorSQLiteSnapshotError.unavailable
    }
}

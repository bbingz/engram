import Darwin
import Foundation

/// One scoped row capture plus coherent workspace ownership, before transport.
enum CollectorCursorLegacyOwnership {
    struct Capture {
        let rows: CollectorCursorLegacySource.ExportedRows
        let cwd: String
        let ownershipPayloadByteCount: Int64
        let logicalDatabaseLocator: String

        func archiveSession() throws -> ArchiveCursorLegacySession {
            try ArchiveCursorLegacySession(logicalDatabaseLocator: logicalDatabaseLocator,
                composerID: rows.composerID, cwd: cwd, databaseGeneration: rows.databaseGeneration,
                walGeneration: rows.walGeneration, composer: rows.composer, bubbles: rows.bubbles)
        }
    }
    struct Budget {
        var rows: CollectorCursorLegacySource.Budget = .init()
        var maximumOwnershipBytes: Int64 = 8 * 1024 * 1024
        var maximumWorkspaces: Int = 4096
        var maximumSQLiteSteps: Int64 = 1_000_000
    }
    struct TestHooks {
        var rows: CollectorCursorLegacySource.TestHooks = .init()
        var beforeSQLiteOpen: ((URL) throws -> Void)?
        var afterWorkspaceRead: ((URL) throws -> Void)?
        var beforeFinalValidation: (() throws -> Void)?
    }

    struct OwnershipObservationPage: Equatable, Sendable {
        var workspaceStorageMissing: Bool
        var membershipFingerprint: String
        var workspaces: [WorkspaceObservation]
        var nextAfter: String?
    }

    struct WorkspaceObservation: Equatable, Sendable {
        var workspaceID: String
        var fingerprint: String
    }

    /// One private global `state.vscdb` image for a discovery page and its captures.
    final class SnapshotLease {
        fileprivate let state: LeaseState

        fileprivate init(state: LeaseState) {
            self.state = state
        }

        var databaseGeneration: ArchiveSourceGeneration { state.global.databaseGeneration }
        var walGeneration: ArchiveSourceGeneration? { state.global.walGeneration }

        func composerIDs(after: String? = nil, limit: Int = 64) throws -> [String] {
            try state.requireActive()
            do {
                let ids = try CollectorCursorLegacySource.composerIDs(
                    snapshot: state.global, after: after, limit: limit,
                    budget: state.rowBudget(), testHooks: state.rowHooks(), clock: state.clock)
                try state.consumeOutput(ids.reduce(into: Int64(0)) { $0 += Int64($1.utf8.count) })
                return ids
            } catch {
                try CollectorCursorLegacyOwnership.mapLeaseError(error)
            }
        }

        func capture(composerID: String) throws -> Capture {
            try state.requireActive()
            try Task.checkCancellation()
            do {
                let rows = try CollectorCursorLegacySource.readRows(
                    snapshot: state.global, composerID: composerID,
                    budget: state.rowBudget(), testHooks: state.rowHooks(), clock: state.clock)
                try state.consumeOutput(rows.rawPayloadByteCount)
                let cwd: String
                if state.root.lastPathComponent.utf8.elementsEqual("globalStorage".utf8) {
                    cwd = try state.ownership.resolve(
                        global: state.global, root: state.root, composerID: composerID,
                        stagingParent: state.stagingParent, hooks: state.testHooks)
                } else {
                    cwd = ""
                }
                try state.testHooks.beforeFinalValidation?()
                try state.global.validateSQLitePair()
                try state.global.validateSourcePair()
                try state.ownership.validateAll()
                try state.global.validateSourcePair()
                return Capture(rows: rows, cwd: cwd, ownershipPayloadByteCount: state.ownership.bytesRead,
                    logicalDatabaseLocator: state.root.appendingPathComponent("state.vscdb").path)
            } catch {
                try CollectorCursorLegacyOwnership.mapLeaseError(error)
            }
        }
    }

    static func withSnapshotLease<T>(
        globalStorageRoot: URL, stagingParent: URL,
        budget: Budget = .init(), testHooks: TestHooks = .init(),
        _ body: (SnapshotLease) throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        guard budget.maximumOwnershipBytes > 0, budget.maximumWorkspaces > 0,
              budget.maximumWorkspaces <= (Int.max - 64) / 4, budget.maximumSQLiteSteps > 0 else {
            throw CollectorCursorLegacySource.LegacyError.exceededBudget
        }
        let rowClock = try LegacyReadClock(budget.rows)
        let ownership = try OwnershipRead(budget: budget)
        do {
            if globalStorageRoot.lastPathComponent.utf8.elementsEqual("globalStorage".utf8) {
                // User-directory membership is an ownership input too. Refuse
                // overlapping staging before even the global clone is created.
                try CollectorSQLiteSnapshotLease.validateStagingParent(
                    root: globalStorageRoot.deletingLastPathComponent(), stagingParent: stagingParent)
            }
            return try CollectorSQLiteSnapshotLease.withSnapshot(
                root: globalStorageRoot, databaseName: "state.vscdb", stagingParent: stagingParent,
                budget: budget.rows.snapshot, testHooks: testHooks.rows.snapshot
            ) { global in
                let state = LeaseState(
                    root: globalStorageRoot, stagingParent: stagingParent, budget: budget,
                    testHooks: testHooks, clock: rowClock, ownership: ownership, global: global)
                defer { state.invalidate() }
                return try body(SnapshotLease(state: state))
            }
        } catch {
            try mapLeaseError(error)
        }
    }

    fileprivate static func mapLeaseError(_ error: Error) throws -> Never {
        if let error = error as? CollectorSQLiteSnapshotError {
            switch error {
            case .exceededBudget: throw CollectorCursorLegacySource.LegacyError.exceededBudget
            case .unavailable: throw CollectorCursorLegacySource.LegacyError.unavailable
            case .unsafePath, .sourceChanged: throw CollectorCursorLegacySource.LegacyError.sourceChanged
            }
        }
        if error is CollectorPOSIXEnumerationError {
            throw CollectorCursorLegacySource.LegacyError.sourceChanged
        }
        throw error
    }

    static func capture(
        globalStorageRoot: URL, composerID: String, stagingParent: URL,
        budget: Budget = .init(), testHooks: TestHooks = .init()
    ) throws -> Capture {
        try withSnapshotLease(
            globalStorageRoot: globalStorageRoot, stagingParent: stagingParent,
            budget: budget, testHooks: testHooks
        ) { lease in
            try lease.capture(composerID: composerID)
        }
    }

    /// Stat-only sibling `workspaceStorage` page. Never opens SQLite or file bytes.
    static func ownershipObservationPage(
        globalStorageRoot: URL, after: String?, limit: Int,
        budget: Budget = .init(), testHooks: TestHooks = .init()
    ) throws -> OwnershipObservationPage {
        try Task.checkCancellation()
        guard (1...64).contains(limit), budget.maximumOwnershipBytes > 0,
              budget.maximumWorkspaces > 0,
              budget.maximumWorkspaces <= (Int.max - 64) / 4 else {
            throw CollectorCursorLegacySource.LegacyError.exceededBudget
        }
        if let after {
            guard !after.isEmpty, !after.utf8.contains(0), !after.utf8.contains(0x2F),
                  after != ".", after != ".." else {
                throw CollectorCursorLegacySource.LegacyError.exceededBudget
            }
        }
        guard globalStorageRoot.lastPathComponent.utf8.elementsEqual("globalStorage".utf8) else {
            throw CollectorCursorLegacySource.LegacyError.sourceChanged
        }
        // Capture hooks stay unused: this page never reads source bytes or SQLite.
        _ = testHooks
        do {
            return try ObservationRead(budget: budget).page(
                globalStorageRoot: globalStorageRoot, after: after, limit: limit)
        } catch {
            try mapLeaseError(error)
        }
    }

    fileprivate final class LeaseState {
        let root: URL
        let stagingParent: URL
        let budget: Budget
        let testHooks: TestHooks
        let clock: LegacyReadClock
        let ownership: OwnershipRead
        let global: CollectorSQLiteSnapshotLease.Snapshot
        var remainingOutputBytes: Int64
        var active = true

        init(
            root: URL, stagingParent: URL, budget: Budget, testHooks: TestHooks,
            clock: LegacyReadClock, ownership: OwnershipRead,
            global: CollectorSQLiteSnapshotLease.Snapshot
        ) {
            self.root = root
            self.stagingParent = stagingParent
            self.budget = budget
            self.testHooks = testHooks
            self.clock = clock
            self.ownership = ownership
            self.global = global
            remainingOutputBytes = budget.rows.maximumOutputBytes
        }

        func requireActive() throws {
            guard active else { throw CollectorCursorLegacySource.LegacyError.unavailable }
        }

        func invalidate() {
            active = false
        }

        func rowBudget() -> CollectorCursorLegacySource.Budget {
            var rows = budget.rows
            rows.maximumOutputBytes = remainingOutputBytes
            return rows
        }

        func rowHooks() -> CollectorCursorLegacySource.TestHooks {
            var hooks = testHooks.rows
            let rowOpen = hooks.beforeSQLiteOpen
            hooks.beforeSQLiteOpen = { [testHooks] url in
                try testHooks.beforeSQLiteOpen?(url)
                try rowOpen?(url)
            }
            return hooks
        }

        func consumeOutput(_ count: Int64) throws {
            guard count >= 0, remainingOutputBytes >= count else {
                throw CollectorCursorLegacySource.LegacyError.exceededBudget
            }
            remainingOutputBytes -= count
        }
    }

    fileprivate final class OwnershipRead {
        typealias Failure = CollectorCursorLegacySource.LegacyError
        struct Input {
            let url: URL
            let generation: ArchiveSourceGeneration?
        }
        let budget: Budget
        let clock: LegacyReadClock
        var inputs: [Data: Input] = [:]
        var bytesRead: Int64 = 0
        var unprovenInput = false
        var didCompleteWalk = false
        var frozenChildNames: [Data]?
        var workspaceReads: [Data: CachedWorkspaceRead] = [:]
        var didReadHeaders = false
        var cachedHeaders: Data?

        struct CachedWorkspaceRead {
            let metadataGeneration: ArchiveSourceGeneration?
            let databaseGeneration: ArchiveSourceGeneration?
            let walGeneration: ArchiveSourceGeneration?
            let jsonRaw: Data?
            let indexRaw: Data?
        }

        init(budget: Budget) throws {
            self.budget = budget
            var sqlBudget = budget.rows
            sqlBudget.maximumSQLiteSteps = budget.maximumSQLiteSteps
            clock = try LegacyReadClock(sqlBudget)
        }

        func resolve(
            global: CollectorSQLiteSnapshotLease.Snapshot, root: URL, composerID: String,
            stagingParent: URL, hooks: TestHooks
        ) throws -> String {
            let user = root.deletingLastPathComponent()
            _ = try remember(user)
            let workspaces = user.appendingPathComponent("workspaceStorage")
            guard let rootInfo = try remember(workspaces) else {
                didCompleteWalk = true
                return ""
            }
            guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
                didCompleteWalk = true
                return ""
            }
            let names = try directoryNames(workspaces, expected: rootInfo)
            let childNames = names.map { Data($0.utf8) }
            if let frozen = frozenChildNames {
                guard frozen.count == childNames.count,
                      zip(frozen, childNames).allSatisfy({ $0.elementsEqual($1) }) else {
                    throw Failure.sourceChanged
                }
            }
            var cwdByWorkspace: [Data: String] = [:]
            var paths: [Data: String] = [:]
            var workspaceCount = 0
            for name in names where !name.hasPrefix(".") {
                try clock.check()
                let workspace = workspaces.appendingPathComponent(name)
                let nameKey = Data(name.utf8)
                guard let directory = try remember(workspace) else { throw Failure.sourceChanged }
                // Native discovery excludes symlink and nondirectory children.
                guard directory.st_mode & S_IFMT == S_IFDIR,
                      directory.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                workspaceCount += 1
                guard workspaceCount <= budget.maximumWorkspaces else { throw Failure.exceededBudget }
                if didCompleteWalk, workspaceReads[nameKey] == nil { throw Failure.sourceChanged }
                let metadataURL = workspace.appendingPathComponent("workspace.json")
                guard let metadataInfo = try remember(metadataURL) else {
                    storeWorkspaceRead(nameKey, CachedWorkspaceRead(
                        metadataGeneration: nil, databaseGeneration: nil, walGeneration: nil,
                        jsonRaw: nil, indexRaw: nil))
                    continue
                }
                guard metadataInfo.st_mode & S_IFMT == S_IFREG else {
                    unprovenInput = true
                    storeWorkspaceRead(nameKey, CachedWorkspaceRead(
                        metadataGeneration: try generation(metadataInfo),
                        databaseGeneration: nil, walGeneration: nil,
                        jsonRaw: nil, indexRaw: nil))
                    continue
                }
                let bytes: Data
                if let cached = workspaceReads[nameKey], let jsonRaw = cached.jsonRaw {
                    guard cached.metadataGeneration == (try generation(metadataInfo)) else {
                        throw Failure.sourceChanged
                    }
                    try charge(Int64(jsonRaw.count))
                    bytes = jsonRaw
                } else {
                    bytes = try readFile(metadataURL, expected: metadataInfo)
                }
                guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
                    unprovenInput = true
                    storeWorkspaceRead(nameKey, CachedWorkspaceRead(
                        metadataGeneration: try generation(metadataInfo),
                        databaseGeneration: nil, walGeneration: nil,
                        jsonRaw: bytes, indexRaw: nil))
                    continue
                }
                guard object["configuration"] == nil, let folder = object["folder"] as? String,
                      let uri = URL(string: folder), uri.isFileURL,
                      uri.host == nil || uri.host == "" || uri.host == "localhost" else {
                    storeWorkspaceRead(nameKey, CachedWorkspaceRead(
                        metadataGeneration: try generation(metadataInfo),
                        databaseGeneration: nil, walGeneration: nil,
                        jsonRaw: bytes, indexRaw: nil))
                    continue
                }
                let cwd = uri.standardizedFileURL.path
                guard cwd.hasPrefix("/"), cwd != "/", !cwd.utf8.contains(0) else {
                    storeWorkspaceRead(nameKey, CachedWorkspaceRead(
                        metadataGeneration: try generation(metadataInfo),
                        databaseGeneration: nil, walGeneration: nil,
                        jsonRaw: bytes, indexRaw: nil))
                    continue
                }
                cwdByWorkspace[nameKey] = cwd
                let database = workspace.appendingPathComponent("state.vscdb")
                let mainInfo = try remember(database)
                let walInfo = try remember(URL(fileURLWithPath: database.path + "-wal"))
                let journalInfo = try remember(URL(fileURLWithPath: database.path + "-journal"))
                // SHM is not ownership data, but an unsafe member must not be opened.
                let shmURL = URL(fileURLWithPath: database.path + "-shm")
                if let shm = try observe(shmURL), shm.st_mode & S_IFMT != S_IFREG { throw Failure.sourceChanged }
                var indexRaw: Data?
                if let mainInfo {
                    guard mainInfo.st_mode & S_IFMT == S_IFREG, journalInfo == nil else { throw Failure.sourceChanged }
                    if let cached = workspaceReads[nameKey],
                       cached.databaseGeneration == (try generation(mainInfo)),
                       cached.walGeneration == (try walInfo.map { try generation($0) }) {
                        indexRaw = cached.indexRaw
                        if let raw = indexRaw { try charge(Int64(raw.count)) }
                    } else {
                        indexRaw = try CollectorSQLiteSnapshotLease.withSnapshot(
                            root: workspace, databaseName: "state.vscdb", stagingParent: stagingParent,
                            budget: budget.rows.snapshot
                        ) { snapshot in
                            guard try generation(mainInfo) == snapshot.databaseGeneration,
                                  try walInfo.map({ try generation($0) }) == snapshot.walGeneration else {
                                throw Failure.sourceChanged
                            }
                            let value = try readIndex(snapshot, key: "composer.composerData", hook: hooks.beforeSQLiteOpen)
                            try snapshot.validateSQLitePair()
                            try snapshot.validateSourcePair()
                            return value
                        }
                    }
                    for record in try indexRecords(indexRaw) {
                        if let id = record["composerId"] as? String, id.utf8.elementsEqual(composerID.utf8) {
                            paths[Data(cwd.utf8)] = cwd
                        }
                    }
                }
                storeWorkspaceRead(nameKey, CachedWorkspaceRead(
                    metadataGeneration: try generation(metadataInfo),
                    databaseGeneration: try mainInfo.map { try generation($0) },
                    walGeneration: try walInfo.map { try generation($0) },
                    jsonRaw: bytes, indexRaw: indexRaw))
                try hooks.afterWorkspaceRead?(workspace)
            }
            let headers: Data?
            if didReadHeaders {
                headers = cachedHeaders
                if let raw = headers { try charge(Int64(raw.count)) }
            } else {
                headers = try readIndex(global, key: "composer.composerHeaders", hook: hooks.beforeSQLiteOpen)
                cachedHeaders = headers
                didReadHeaders = true
            }
            for record in try indexRecords(headers) {
                guard let id = record["composerId"] as? String, id.utf8.elementsEqual(composerID.utf8),
                      let identifier = record["workspaceIdentifier"] as? [String: Any],
                      let workspaceID = identifier["id"] as? String,
                      let cwd = cwdByWorkspace[Data(workspaceID.utf8)] else { continue }
                paths[Data(cwd.utf8)] = cwd
            }
            if frozenChildNames == nil { frozenChildNames = childNames }
            didCompleteWalk = true
            return !unprovenInput && paths.count == 1 ? paths.values.first! : ""
        }

        func readIndex(
            _ snapshot: CollectorSQLiteSnapshotLease.Snapshot, key: String, hook: ((URL) throws -> Void)?
        ) throws -> Data? {
            var sqlBudget = budget.rows
            // Schema strings have a separate bounded allocation; charge only
            // metadata bytes to the cumulative ownership budget below.
            sqlBudget.maximumOutputBytes = max(4096, budget.maximumOwnershipBytes - bytesRead)
            let raw = try CollectorCursorLegacySource.readOwnershipIndex(
                snapshot: snapshot, key: key, budget: sqlBudget, clock: clock, beforeSQLiteOpen: hook
            )
            if let raw { try charge(Int64(raw.count)) }
            return raw
        }

        func indexRecords(_ raw: Data?) throws -> [[String: Any]] {
            guard let raw else { return [] }
            try clock.check()
            guard !raw.contains(0), String(data: raw, encoding: .utf8) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
                throw Failure.unsupportedSchema
            }
            guard let value = object["allComposers"] else { return [] }
            guard let array = value as? [Any] else { throw Failure.unsupportedSchema }
            return array.compactMap { $0 as? [String: Any] }
        }

        func charge(_ count: Int64) throws {
            let next = bytesRead.addingReportingOverflow(count)
            guard count >= 0, !next.overflow, next.partialValue <= budget.maximumOwnershipBytes else {
                throw Failure.exceededBudget
            }
            bytesRead = next.partialValue
            try clock.check()
        }

        func remember(_ url: URL) throws -> stat? {
            let info = try observe(url)
            let observed = try info.map { try generation($0) }
            let key = Data(url.path.utf8)
            if let prior = inputs[key] {
                guard prior.generation == observed else { throw Failure.sourceChanged }
                return info
            }
            if didCompleteWalk { throw Failure.sourceChanged }
            inputs[key] = Input(url: url, generation: observed)
            return info
        }

        func storeWorkspaceRead(_ key: Data, _ value: CachedWorkspaceRead) {
            guard workspaceReads[key] == nil else { return }
            workspaceReads[key] = value
        }

        func validateAll() throws {
            for input in inputs.values {
                try clock.check()
                do {
                    guard try observe(input.url).map({ try generation($0) }) == input.generation else {
                        throw Failure.sourceChanged
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw Failure.sourceChanged
                }
            }
            try clock.check()
        }

        func observe(_ url: URL) throws -> stat? {
            try clock.check()
            let parent = try CollectorPOSIXDirectoryAccess.openAbsolute(
                components: CollectorPOSIXDirectoryAccess.components(url.deletingLastPathComponent().path))
            defer { CollectorPOSIXDirectoryAccess.close(parent.descriptor) }
            var info = stat()
            let status = url.lastPathComponent.withCString {
                fstatat(parent.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0 {
                if errno == ENOENT { return nil }
                throw Failure.unavailable
            }
            return info
        }

        func readFile(_ url: URL, expected: stat) throws -> Data {
            guard expected.st_size >= 0, Int64(expected.st_size) <= budget.maximumOwnershipBytes - bytesRead,
                  let size = Int(exactly: expected.st_size) else { throw Failure.exceededBudget }
            let parent = try CollectorPOSIXDirectoryAccess.openAbsolute(
                components: CollectorPOSIXDirectoryAccess.components(url.deletingLastPathComponent().path))
            defer { CollectorPOSIXDirectoryAccess.close(parent.descriptor) }
            let fd = url.lastPathComponent.withCString {
                openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard fd >= 0 else { throw Failure.sourceChanged }
            defer { Darwin.close(fd) }
            var live = stat()
            guard fstat(fd, &live) == 0, try generation(live) == generation(expected) else { throw Failure.sourceChanged }
            var result = Data(count: size)
            try result.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < size {
                    try clock.check()
                    let count = pread(fd, buffer.baseAddress!.advanced(by: offset), min(64 * 1024, size - offset), off_t(offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure.sourceChanged }
                    offset += count
                }
            }
            guard fstat(fd, &live) == 0, try generation(live) == generation(expected),
                  try observe(url).map({ try generation($0) }) == generation(expected) else { throw Failure.sourceChanged }
            try charge(Int64(result.count))
            return result
        }

        func directoryNames(_ url: URL, expected: stat) throws -> [String] {
            let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(
                components: CollectorPOSIXDirectoryAccess.components(url.path))
            defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
            guard try generation(opened.info) == generation(expected) else { throw Failure.sourceChanged }
            let copied = try CollectorCursorSource.duplicateDirectoryDescriptor(opened.descriptor)
            guard let stream = fdopendir(copied) else {
                Darwin.close(copied)
                throw Failure.unavailable
            }
            defer { closedir(stream) }
            var names: [String] = []
            let entryLimit = budget.maximumWorkspaces * 4 + 64
            while true {
                try clock.check()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw Failure.unavailable }
                    break
                }
                var value = entry.pointee
                let count = Int(value.d_namlen)
                let name = try withUnsafeBytes(of: &value.d_name) { raw in
                    guard count > 0, count < raw.count, raw[count] == 0 else { throw Failure.sourceChanged }
                    return try CollectorPOSIXRootEnumerator.decodeEntryName(Data(raw.prefix(count)))
                }
                if name == "." || name == ".." { continue }
                guard names.count < entryLimit else { throw Failure.exceededBudget }
                names.append(name)
            }
            guard try generation(CollectorPOSIXDirectoryAccess.directoryStat(opened.descriptor)) == generation(expected) else {
                throw Failure.sourceChanged
            }
            return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }

        func generation(_ info: stat) throws -> ArchiveSourceGeneration {
            func nanos(_ value: timespec) throws -> Int64 {
                let seconds = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
                let result = seconds.partialValue.addingReportingOverflow(Int64(value.tv_nsec))
                guard !seconds.overflow, !result.overflow else { throw Failure.sourceChanged }
                return result.partialValue
            }
            guard let inode = Int64(exactly: info.st_ino), info.st_size >= 0 else { throw Failure.sourceChanged }
            return try ArchiveSourceGeneration(device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
                mtimeNs: nanos(info.st_mtimespec), ctimeNs: nanos(info.st_ctimespec), mode: Int64(info.st_mode))
        }
    }

    fileprivate final class ObservationRead {
        typealias Failure = CollectorCursorLegacySource.LegacyError
        let budget: Budget
        var bytesRead: Int64 = 0

        init(budget: Budget) {
            self.budget = budget
        }

        func page(
            globalStorageRoot: URL, after: String?, limit: Int
        ) throws -> OwnershipObservationPage {
            let user = globalStorageRoot.deletingLastPathComponent()
            let userOpened = try CollectorPOSIXDirectoryAccess.openAbsolute(
                components: CollectorPOSIXDirectoryAccess.components(user.path))
            defer { CollectorPOSIXDirectoryAccess.close(userOpened.descriptor) }
            let userIdentity = try CollectorPOSIXDirectoryAccess.identity(userOpened.info)
            let globalOpened = try CollectorPOSIXDirectoryAccess.openAbsolute(
                components: CollectorPOSIXDirectoryAccess.components(globalStorageRoot.path))
            defer { CollectorPOSIXDirectoryAccess.close(globalOpened.descriptor) }
            let globalIdentity = try CollectorPOSIXDirectoryAccess.identity(globalOpened.info)
            var info = stat()
            let status = "workspaceStorage".withCString {
                fstatat(userOpened.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0 {
                guard errno == ENOENT else { throw Failure.unavailable }
                try requireIdentity(userOpened.descriptor, userIdentity)
                try requireIdentity(globalOpened.descriptor, globalIdentity)
                return try missingPage()
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.sourceChanged }
            let workspaces = try CollectorPOSIXDirectoryAccess.openComponent(
                "workspaceStorage", parent: userOpened.descriptor)
            defer { CollectorPOSIXDirectoryAccess.close(workspaces) }
            let storageInfo = try CollectorPOSIXDirectoryAccess.directoryStat(workspaces)
            guard try generation(storageInfo) == generation(info) else { throw Failure.sourceChanged }
            let storageIdentity = try CollectorPOSIXDirectoryAccess.identity(storageInfo)
            let names = try directoryNames(descriptor: workspaces, expected: storageInfo)
            var accepted: [String] = []
            for name in names where !name.hasPrefix(".") {
                try Task.checkCancellation()
                guard let child = try namedStat(workspaces, name) else { throw Failure.sourceChanged }
                guard child.st_mode & S_IFMT == S_IFDIR,
                      child.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                accepted.append(name)
                guard accepted.count <= budget.maximumWorkspaces else { throw Failure.exceededBudget }
                try charge(Int64(name.utf8.count))
            }
            let membership = try fingerprint(
                prefix: "cursor-legacy-ownership-membership-v1:",
                PresentMembership(identity: storageIdentity, ids: accepted))
            let remaining = accepted.filter { id in
                after.map { $0.utf8.lexicographicallyPrecedes(id.utf8) } ?? true
            }
            let pageIDs = Array(remaining.prefix(limit))
            var workspacesPage: [WorkspaceObservation] = []
            workspacesPage.reserveCapacity(pageIDs.count)
            for id in pageIDs {
                try Task.checkCancellation()
                workspacesPage.append(try observeWorkspace(parent: workspaces, id: id))
            }
            try requireIdentity(userOpened.descriptor, userIdentity)
            try requireIdentity(globalOpened.descriptor, globalIdentity)
            try requireIdentity(workspaces, storageIdentity)
            return OwnershipObservationPage(
                workspaceStorageMissing: false,
                membershipFingerprint: membership,
                workspaces: workspacesPage,
                nextAfter: pageIDs.count < remaining.count ? pageIDs.last : nil)
        }

        func missingPage() throws -> OwnershipObservationPage {
            struct AbsentMembership: Encodable {
                let workspaceStorage = "absent"
            }
            return OwnershipObservationPage(
                workspaceStorageMissing: true,
                membershipFingerprint: try fingerprint(
                    prefix: "cursor-legacy-ownership-membership-v1:", AbsentMembership()),
                workspaces: [],
                nextAfter: nil)
        }

        func observeWorkspace(parent: Int32, id: String) throws -> WorkspaceObservation {
            let opened = try CollectorPOSIXDirectoryAccess.openComponent(id, parent: parent)
            defer { CollectorPOSIXDirectoryAccess.close(opened) }
            let directory = try CollectorPOSIXDirectoryAccess.directoryStat(opened)
            let json = try namedStat(opened, "workspace.json")
            let database = try namedStat(opened, "state.vscdb")
            let wal = try namedStat(opened, "state.vscdb-wal")
            let fingerprint = try fingerprint(
                prefix: "cursor-legacy-ownership-workspace-v1:",
                WorkspaceMembership(
                    id: id,
                    directory: try generation(directory),
                    json: try json.map(generation),
                    database: try database.map(generation),
                    wal: try wal.map(generation)))
            return WorkspaceObservation(workspaceID: id, fingerprint: fingerprint)
        }

        func fingerprint(prefix: String, _ value: some Encodable) throws -> String {
            let encoded = try ArchiveCanonicalJSON.encode(value)
            try charge(Int64(encoded.count))
            return prefix + ArchiveV2Hash.sha256(encoded)
        }

        func directoryNames(descriptor: Int32, expected: stat) throws -> [String] {
            guard try generation(CollectorPOSIXDirectoryAccess.directoryStat(descriptor)) == generation(expected) else {
                throw Failure.sourceChanged
            }
            let copied = try CollectorCursorSource.duplicateDirectoryDescriptor(descriptor)
            guard let stream = fdopendir(copied) else {
                Darwin.close(copied)
                throw Failure.unavailable
            }
            defer { closedir(stream) }
            var names: [String] = []
            let entryLimit = budget.maximumWorkspaces * 4 + 64
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw Failure.unavailable }
                    break
                }
                var value = entry.pointee
                let count = Int(value.d_namlen)
                let name = try withUnsafeBytes(of: &value.d_name) { raw in
                    guard count > 0, count < raw.count, raw[count] == 0 else { throw Failure.sourceChanged }
                    return try CollectorPOSIXRootEnumerator.decodeEntryName(Data(raw.prefix(count)))
                }
                if name == "." || name == ".." { continue }
                guard names.count < entryLimit else { throw Failure.exceededBudget }
                names.append(name)
            }
            guard try generation(CollectorPOSIXDirectoryAccess.directoryStat(descriptor)) == generation(expected) else {
                throw Failure.sourceChanged
            }
            return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }

        func namedStat(_ parent: Int32, _ name: String) throws -> stat? {
            try Task.checkCancellation()
            var info = stat()
            let status = name.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
            if status != 0 {
                if errno == ENOENT { return nil }
                throw Failure.unavailable
            }
            return info
        }

        func requireIdentity(_ descriptor: Int32, _ expected: CollectorPOSIXDirectoryIdentity) throws {
            let live = try CollectorPOSIXDirectoryAccess.identity(
                CollectorPOSIXDirectoryAccess.directoryStat(descriptor))
            guard live == expected else { throw Failure.sourceChanged }
        }

        func charge(_ count: Int64) throws {
            let next = bytesRead.addingReportingOverflow(count)
            guard count >= 0, !next.overflow, next.partialValue <= budget.maximumOwnershipBytes else {
                throw Failure.exceededBudget
            }
            bytesRead = next.partialValue
        }

        func generation(_ info: stat) throws -> ArchiveSourceGeneration {
            func nanos(_ value: timespec) throws -> Int64 {
                let seconds = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
                let result = seconds.partialValue.addingReportingOverflow(Int64(value.tv_nsec))
                guard !seconds.overflow, !result.overflow else { throw Failure.sourceChanged }
                return result.partialValue
            }
            guard let inode = Int64(exactly: info.st_ino), info.st_size >= 0 else { throw Failure.sourceChanged }
            return try ArchiveSourceGeneration(device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
                mtimeNs: nanos(info.st_mtimespec), ctimeNs: nanos(info.st_ctimespec), mode: Int64(info.st_mode))
        }
    }

    private struct PresentMembership: Encodable {
        let device: Int64
        let inode: Int64
        let generation: UInt32
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let ids: [String]

        init(identity: CollectorPOSIXDirectoryIdentity, ids: [String]) {
            device = identity.device
            inode = identity.inode
            generation = identity.generation
            birthSeconds = identity.birthSeconds
            birthNanoseconds = identity.birthNanoseconds
            self.ids = ids
        }
    }

    private struct WorkspaceMembership: Encodable {
        let id: String
        let directory: ArchiveSourceGeneration
        let json: ArchiveSourceGeneration?
        let database: ArchiveSourceGeneration?
        let wal: ArchiveSourceGeneration?
    }
}

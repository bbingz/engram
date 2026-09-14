import Darwin
import Foundation

@_silgen_name("fclonefileat")
private func sys_fclonefileat(_ srcfd: Int32, _ dst_dirfd: Int32, _ dst: UnsafePointer<CChar>?, _ flags: UInt32) -> Int32

enum CollectorSQLiteSnapshotError: Error, Equatable {
    case unavailable
    case unsafePath
    case sourceChanged
    case exceededBudget
}

/// Private main/WAL file custody only. Consumers own bounded SQL and scoped export.
/// A shared source database must never be uploaded as one session.
enum CollectorSQLiteSnapshotLease {
    struct Budget {
        var maximumSnapshotByteCount: Int64 = 1024 * 1024 * 1024
        var maximumCopyByteCount: Int64 = 16 * 1024 * 1024
        var maximumLeaseMilliseconds: Int = 5_000
    }

    struct TestHooks {
        var afterSourceDescriptorsOpened: (() throws -> Void)?
        var afterPrivateMainCopy: (() throws -> Void)?
        var beforeSnapshotUse: ((URL) throws -> Void)?
        var didStageSourceFile: ((String, Bool, Int64) -> Void)?
        var forceStreamingCopy: Bool = false
    }

    struct Snapshot {
        let privateDatabaseURL: URL
        let databaseGeneration: ArchiveSourceGeneration
        let walGeneration: ArchiveSourceGeneration?
        fileprivate let rawPairValidation: () throws -> Void
        fileprivate let sqlitePairValidation: () throws -> Void
        fileprivate let sourcePairValidation: () throws -> Void

        /// Only for raw-byte consumers before SQLite creates private sidecars.
        func validateRawPair() throws { try rawPairValidation() }
        /// SQL readers may create a private WAL index; main/WAL remain sealed.
        func validateSQLitePair() throws { try sqlitePairValidation() }
        /// Revalidate the original root and source members after a scoped SQL read.
        func validateSourcePair() throws { try sourcePairValidation() }
    }

    /// Materialize immutable captured bytes; there is no live source to reopen.
    static func withCapturedPair<T>(
        databaseBytes: Data, walBytes: Data?, databaseName: String, stagingParent: URL,
        budget: Budget = .init(), testHooks: TestHooks = .init(), _ body: (URL, () throws -> Void) throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        try validateBudget(budget)
        try validateDatabaseName(databaseName)
        let total = Int64(databaseBytes.count).addingReportingOverflow(Int64(walBytes?.count ?? 0))
        guard !total.overflow, total.partialValue <= budget.maximumSnapshotByteCount,
              total.partialValue <= budget.maximumCopyByteCount else { throw CollectorSQLiteSnapshotError.exceededBudget }
        let clock = try LeaseClock(milliseconds: budget.maximumLeaseMilliseconds)
        var staging = try createOwnedStaging(stagingParent, databaseName: databaseName)
        defer { destroyOwnedStaging(&staging) }
        func write(_ bytes: Data, name: String) throws {
            try clock.check()
            let fd = name.withCString { openat(staging.childFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard fd >= 0 else { throw CollectorSQLiteSnapshotError.unavailable }
            defer { Darwin.close(fd) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try clock.check()
                    let count = pwrite(fd, buffer.baseAddress!.advanced(by: offset), min(64 * 1024, buffer.count - offset), off_t(offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CollectorSQLiteSnapshotError.unavailable }
                    offset += count
                }
            }
            try verifyStagedFile(staging.childFD, name, expectedSize: off_t(bytes.count))
        }
        try write(databaseBytes, name: databaseName)
        if let walBytes { try write(walBytes, name: databaseName + "-wal") }
        try rememberStagedPair(&staging)
        let url = stagingParent.appendingPathComponent(staging.childName).appendingPathComponent(databaseName)
        try testHooks.beforeSnapshotUse?(url)
        try clock.check()
        try confirmOwnedStaging(staging, parentURL: stagingParent)
        let lifetime = SnapshotLifetime()
        defer { lifetime.active = false }
        let sealed = staging
        let result = try body(url, {
            guard lifetime.active else { throw CollectorSQLiteSnapshotError.unavailable }
            try clock.check()
            // SQLite may create its private WAL index. Main/WAL bytes and
            // pathname bindings must still match before the consumer closes it.
            try confirmOwnedStaging(sealed, parentURL: stagingParent, allowSQLiteSHM: true)
        })
        try clock.check()
        return result
    }

    static func withSnapshot<T>(
        root: URL, databaseName: String, stagingParent: URL,
        budget: Budget = .init(), testHooks: TestHooks = .init(),
        _ body: (Snapshot) throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        try validateBudget(budget)
        try validateDatabaseName(databaseName)
        let walName = databaseName + "-wal"
        let shmName = databaseName + "-shm"
        let journalName = databaseName + "-journal"
        let clock = try LeaseClock(milliseconds: budget.maximumLeaseMilliseconds)
        try clock.check()
        let openedRoot = try openRoot(root)
        defer { CollectorPOSIXDirectoryAccess.close(openedRoot.descriptor) }
        try requireSeparateStaging(source: openedRoot, stagingParent: stagingParent)
        if try namedStat(openedRoot.descriptor, journalName) != nil {
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        if let shm = try namedStat(openedRoot.descriptor, shmName) {
            try requireRegular(shm)
        }
        let main = try openSourceRegular(openedRoot.descriptor, databaseName)
        defer { main.close() }
        let wal: SourceFD?
        if try namedStat(openedRoot.descriptor, walName) != nil {
            wal = try openSourceRegular(openedRoot.descriptor, walName)
        } else {
            wal = nil
        }
        defer { wal?.close() }
        try testHooks.afterSourceDescriptorsOpened?()
        try clock.check()
        try confirmRootIdentity(openedRoot)
        try assertNameMatches(openedRoot.descriptor, databaseName, main)
        if let wal {
            try assertNameMatches(openedRoot.descriptor, walName, wal)
        } else if try namedStat(openedRoot.descriptor, walName) != nil {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
        if try namedStat(openedRoot.descriptor, journalName) != nil {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
        if let shm = try namedStat(openedRoot.descriptor, shmName) {
            try requireRegular(shm)
        }
        guard fstat(main.fd, &main.info) == 0 else { throw CollectorSQLiteSnapshotError.sourceChanged }
        if let wal {
            guard fstat(wal.fd, &wal.info) == 0 else { throw CollectorSQLiteSnapshotError.sourceChanged }
        }
        let beforeMain = try generation(from: main.info)
        let beforeWAL = try wal.map { try generation(from: $0.info) }
        var logical = beforeMain.size
        if let beforeWAL {
            let next = logical.addingReportingOverflow(beforeWAL.size)
            guard !next.overflow else { throw CollectorSQLiteSnapshotError.exceededBudget }
            logical = next.partialValue
        }
        guard logical <= budget.maximumSnapshotByteCount else { throw CollectorSQLiteSnapshotError.exceededBudget }
        if testHooks.forceStreamingCopy, logical > budget.maximumCopyByteCount {
            throw CollectorSQLiteSnapshotError.exceededBudget
        }
        func validateSourcePair() throws {
            var afterMain = stat()
            guard fstat(main.fd, &afterMain) == 0,
                  try generation(from: afterMain) == beforeMain else {
                throw CollectorSQLiteSnapshotError.sourceChanged
            }
            try assertNameMatches(openedRoot.descriptor, databaseName, main)
            if let wal {
                var afterWAL = stat()
                guard fstat(wal.fd, &afterWAL) == 0,
                      try generation(from: afterWAL) == beforeWAL else {
                    throw CollectorSQLiteSnapshotError.sourceChanged
                }
                try assertNameMatches(openedRoot.descriptor, walName, wal)
            } else if try namedStat(openedRoot.descriptor, walName) != nil {
                throw CollectorSQLiteSnapshotError.sourceChanged
            }
            if try namedStat(openedRoot.descriptor, journalName) != nil {
                throw CollectorSQLiteSnapshotError.sourceChanged
            }
            try confirmRootIdentity(openedRoot)
            if let shm = try namedStat(openedRoot.descriptor, shmName) { try requireRegular(shm) }
        }
        var staging = try createOwnedStaging(stagingParent, databaseName: databaseName)
        defer { destroyOwnedStaging(&staging) }
        var allowClone = !testHooks.forceStreamingCopy
        var copyRemaining = budget.maximumCopyByteCount
        try stage(
            main, directory: staging.childFD, name: databaseName,
            allowClone: &allowClone, copyRemaining: &copyRemaining,
            budget: budget, clock: clock, hooks: testHooks
        )
        try testHooks.afterPrivateMainCopy?()
        try clock.check()
        try validateSourcePair()
        if let wal {
            try stage(
                wal, directory: staging.childFD, name: walName,
                allowClone: &allowClone, copyRemaining: &copyRemaining,
                budget: budget, clock: clock, hooks: testHooks
            )
        }
        try validateSourcePair()
        try rememberStagedPair(&staging)
        main.close()
        wal?.close()
        let privateURL = stagingParent
            .appendingPathComponent(staging.childName)
            .appendingPathComponent(databaseName)
        try testHooks.beforeSnapshotUse?(privateURL)
        try clock.check()
        try confirmOwnedStaging(staging, parentURL: stagingParent)
        let lifetime = SnapshotLifetime()
        defer { lifetime.active = false }
        let sealedStaging = staging
        return try body(Snapshot(privateDatabaseURL: privateURL,
            databaseGeneration: beforeMain, walGeneration: beforeWAL,
            rawPairValidation: {
                guard lifetime.active else { throw CollectorSQLiteSnapshotError.unavailable }
                try clock.check()
                try confirmOwnedStaging(sealedStaging, parentURL: stagingParent)
            }, sqlitePairValidation: {
                guard lifetime.active else { throw CollectorSQLiteSnapshotError.unavailable }
                try clock.check()
                try confirmOwnedStaging(sealedStaging, parentURL: stagingParent, allowSQLiteSHM: true)
            }, sourcePairValidation: {
                guard lifetime.active else { throw CollectorSQLiteSnapshotError.unavailable }
                try clock.check()
                do {
                    try confirmRootIdentity(openedRoot)
                    let currentMain = try openSourceRegular(openedRoot.descriptor, databaseName)
                    defer { currentMain.close() }
                    let currentWAL = try namedStat(openedRoot.descriptor, walName)
                    if let currentWAL { try requireRegular(currentWAL) }
                    guard try generation(from: currentMain.info) == beforeMain,
                          try currentWAL.map({ try generation(from: $0) }) == beforeWAL,
                          try namedStat(openedRoot.descriptor, journalName) == nil else {
                        throw CollectorSQLiteSnapshotError.sourceChanged
                    }
                    if let shm = try namedStat(openedRoot.descriptor, shmName) { try requireRegular(shm) }
                    try assertNameMatches(openedRoot.descriptor, databaseName, currentMain)
                    try confirmRootIdentity(openedRoot)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw CollectorSQLiteSnapshotError.sourceChanged
                }
                try clock.check()
            }))
    }

    static func observe(root: URL, databaseName: String) throws -> (
        databaseGeneration: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?
    ) {
        try Task.checkCancellation()
        try validateDatabaseName(databaseName)
        let opened = try openRoot(root)
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        let main = try openSourceRegular(opened.descriptor, databaseName)
        defer { main.close() }
        let wal = try namedStat(opened.descriptor, databaseName + "-wal")
        if let wal { try requireRegular(wal) }
        try confirmRootIdentity(opened)
        return (try generation(from: main.info), try wal.map { try generation(from: $0) })
    }

    static func validateStagingParent(root: URL, stagingParent: URL) throws {
        let opened = try openRoot(root)
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        try requireSeparateStaging(source: opened, stagingParent: stagingParent)
    }

    private static func validateDatabaseName(_ name: String) throws {
        guard CollectorInventoryStore.isSafeRelativePath(name), !name.contains("/"),
              name.utf8.count <= Int(MAXNAMLEN) - "-journal".utf8.count else {
            throw CollectorSQLiteSnapshotError.unsafePath
        }
    }

    private static func validateBudget(_ budget: Budget) throws {
        guard budget.maximumSnapshotByteCount >= 0, budget.maximumCopyByteCount >= 0,
              budget.maximumLeaseMilliseconds >= 0 else { throw CollectorSQLiteSnapshotError.exceededBudget }
    }

    // Compare real descriptor ancestry as well as spelling: macOS firmlink
    // aliases must not let private staging write into the source tree.
    private static func requireSeparateStaging(source: OpenedRoot, stagingParent: URL) throws {
        let parent = try openRoot(stagingParent)
        var descriptor = parent.descriptor
        defer { CollectorPOSIXDirectoryAccess.close(descriptor) }
        for _ in 0...CollectorPOSIXRootEnumerator.maximumAbsoluteComponents {
            let info = try CollectorPOSIXDirectoryAccess.directoryStat(descriptor)
            guard info.st_dev != source.info.st_dev || info.st_ino != source.info.st_ino else {
                throw CollectorSQLiteSnapshotError.unsafePath
            }
            let next = try CollectorPOSIXDirectoryAccess.openComponent("..", parent: descriptor)
            let nextInfo: stat
            do { nextInfo = try CollectorPOSIXDirectoryAccess.directoryStat(next) }
            catch { CollectorPOSIXDirectoryAccess.close(next); throw error }
            CollectorPOSIXDirectoryAccess.close(descriptor)
            descriptor = next
            if nextInfo.st_dev == info.st_dev && nextInfo.st_ino == info.st_ino { return }
        }
        throw CollectorSQLiteSnapshotError.unsafePath
    }

    private static func openRoot(_ url: URL) throws -> OpenedRoot {
        let components: [String]
        do {
            components = try CollectorPOSIXDirectoryAccess.components(url.path)
        } catch {
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        do {
            let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
            return OpenedRoot(url: url, descriptor: opened.descriptor, info: opened.info)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CollectorSQLiteSnapshotError.unsafePath
        }
    }

    private static func confirmRootIdentity(_ expected: OpenedRoot) throws {
        let current = try openRoot(expected.url)
        defer { CollectorPOSIXDirectoryAccess.close(current.descriptor) }
        guard current.info.st_dev == expected.info.st_dev, current.info.st_ino == expected.info.st_ino else {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
    }

    private static func namedStat(_ directory: Int32, _ name: String) throws -> stat? {
        var info = stat()
        let status = name.withCString { fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status == 0 { return info }
        if errno == ENOENT { return nil }
        throw CollectorSQLiteSnapshotError.unavailable
    }

    private static func requireRegular(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw CollectorSQLiteSnapshotError.unsafePath }
    }

    private static func openSourceRegular(_ directory: Int32, _ name: String) throws -> SourceFD {
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw errno == ENOENT ? CollectorSQLiteSnapshotError.unavailable : CollectorSQLiteSnapshotError.unsafePath
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            Darwin.close(descriptor)
            throw CollectorSQLiteSnapshotError.unavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        return SourceFD(fd: descriptor, info: info)
    }

    private static func assertNameMatches(_ directory: Int32, _ name: String, _ opened: SourceFD) throws {
        guard let named = try namedStat(directory, name) else { throw CollectorSQLiteSnapshotError.sourceChanged }
        try requireRegular(named)
        var live = stat()
        guard fstat(opened.fd, &live) == 0 else { throw CollectorSQLiteSnapshotError.sourceChanged }
        guard named.st_dev == live.st_dev, named.st_ino == live.st_ino,
              named.st_dev == opened.info.st_dev, named.st_ino == opened.info.st_ino else {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
    }

    private static func createOwnedStaging(_ stagingParent: URL, databaseName: String) throws -> OwnedStaging {
        let parent = try openRoot(stagingParent)
        let childName = UUID().uuidString
        guard childName.withCString({ mkdirat(parent.descriptor, $0, 0o700) }) == 0 else {
            CollectorPOSIXDirectoryAccess.close(parent.descriptor)
            throw CollectorSQLiteSnapshotError.unavailable
        }
        _ = childName.withCString { fchmodat(parent.descriptor, $0, 0o700, 0) }
        let child = childName.withCString {
            openat(parent.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard child >= 0 else {
            _ = childName.withCString { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
            CollectorPOSIXDirectoryAccess.close(parent.descriptor)
            throw CollectorSQLiteSnapshotError.unavailable
        }
        var info = stat()
        var named = stat()
        guard fstat(child, &info) == 0,
              childName.withCString({ fstatat(parent.descriptor, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              info.st_dev == named.st_dev, info.st_ino == named.st_ino,
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700 else {
            Darwin.close(child)
            _ = childName.withCString { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
            CollectorPOSIXDirectoryAccess.close(parent.descriptor)
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        return OwnedStaging(
            databaseName: databaseName, parentFD: parent.descriptor, childFD: child, childName: childName,
            parentDev: parent.info.st_dev, parentIno: parent.info.st_ino,
            childDev: info.st_dev, childIno: info.st_ino
        )
    }

    private static func rememberStagedPair(_ staging: inout OwnedStaging) throws {
        guard let main = try namedStat(staging.childFD, staging.databaseName) else {
            throw CollectorSQLiteSnapshotError.unavailable
        }
        try requireRegular(main)
        staging.mainGeneration = try generation(from: main)
        staging.walGeneration = try namedStat(staging.childFD, staging.databaseName + "-wal")
            .map { try generation(from: $0) }
    }

    private static func confirmOwnedStaging(_ staging: OwnedStaging, parentURL: URL, allowSQLiteSHM: Bool = false) throws {
        var parentLive = stat()
        var childLive = stat()
        guard staging.parentFD >= 0, staging.childFD >= 0,
              fstat(staging.parentFD, &parentLive) == 0, fstat(staging.childFD, &childLive) == 0,
              parentLive.st_dev == staging.parentDev, parentLive.st_ino == staging.parentIno,
              childLive.st_dev == staging.childDev, childLive.st_ino == staging.childIno,
              (childLive.st_mode & S_IFMT) == S_IFDIR else {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
        guard let namedChild = try namedStat(staging.parentFD, staging.childName),
              (namedChild.st_mode & S_IFMT) == S_IFDIR,
              namedChild.st_dev == staging.childDev, namedChild.st_ino == staging.childIno else {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
        do {
            let walked = try openRoot(parentURL)
            defer { CollectorPOSIXDirectoryAccess.close(walked.descriptor) }
            guard walked.info.st_dev == staging.parentDev, walked.info.st_ino == staging.parentIno else {
                throw CollectorSQLiteSnapshotError.sourceChanged
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CollectorSQLiteSnapshotError {
            throw error
        } catch {
            throw CollectorSQLiteSnapshotError.unsafePath
        }
        guard let expectedMain = staging.mainGeneration,
              let main = try namedStat(staging.childFD, staging.databaseName) else {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
        try requireRegular(main)
        guard try generation(from: main) == expectedMain else {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
        let wal = try namedStat(staging.childFD, staging.databaseName + "-wal")
            .map { info in
                try requireRegular(info)
                return try generation(from: info)
            }
        guard wal == staging.walGeneration,
              try namedStat(staging.childFD, staging.databaseName + "-journal") == nil else {
            throw CollectorSQLiteSnapshotError.sourceChanged
        }
        if let shm = try namedStat(staging.childFD, staging.databaseName + "-shm") {
            guard allowSQLiteSHM else { throw CollectorSQLiteSnapshotError.sourceChanged }
            try requireRegular(shm)
        }
    }

    private static func destroyOwnedStaging(_ staging: inout OwnedStaging) {
        if staging.childFD >= 0 {
            var info = stat()
            if fstat(staging.childFD, &info) == 0,
               info.st_dev == staging.childDev, info.st_ino == staging.childIno {
                for name in [staging.databaseName + "-shm", staging.databaseName + "-wal", staging.databaseName + "-journal", staging.databaseName] {
                    _ = name.withCString { unlinkat(staging.childFD, $0, 0) }
                }
            }
            Darwin.close(staging.childFD)
            staging.childFD = -1
        }
        if staging.parentFD >= 0 {
            if !staging.childName.isEmpty {
                var named = stat()
                if staging.childName.withCString({
                    fstatat(staging.parentFD, $0, &named, AT_SYMLINK_NOFOLLOW)
                }) == 0, named.st_dev == staging.childDev, named.st_ino == staging.childIno {
                    _ = staging.childName.withCString { unlinkat(staging.parentFD, $0, AT_REMOVEDIR) }
                }
            }
            Darwin.close(staging.parentFD)
            staging.parentFD = -1
        }
    }

    private static func stage(
        _ source: SourceFD, directory: Int32, name: String,
        allowClone: inout Bool, copyRemaining: inout Int64,
        budget: Budget, clock: LeaseClock, hooks: TestHooks
    ) throws {
        _ = budget
        try clock.check()
        if allowClone, try attemptClone(source: source.fd, directory: directory, name: name, expectedSize: source.info.st_size) {
            hooks.didStageSourceFile?(name, true, 0)
            return
        }
        allowClone = false
        let size = Int64(source.info.st_size)
        guard size >= 0, size <= copyRemaining else { throw CollectorSQLiteSnapshotError.exceededBudget }
        let copied = try streamCopy(
            source: source.fd, directory: directory, name: name,
            expectedSize: source.info.st_size, clock: clock
        )
        copyRemaining -= copied
        hooks.didStageSourceFile?(name, false, copied)
    }

    private static func attemptClone(source: Int32, directory: Int32, name: String, expectedSize: off_t) throws -> Bool {
        let status = name.withCString { sys_fclonefileat(source, directory, $0, 0x0001 | 0x0002) }
        if status == 0 {
            _ = name.withCString { fchmodat(directory, $0, 0o600, 0) }
            try verifyStagedFile(directory, name, expectedSize: expectedSize)
            return true
        }
        if errno == ENOTSUP || errno == EXDEV { return false }
        throw CollectorSQLiteSnapshotError.unavailable
    }

    private static func streamCopy(
        source: Int32, directory: Int32, name: String, expectedSize: off_t, clock: LeaseClock
    ) throws -> Int64 {
        try clock.check()
        let dest = name.withCString { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        guard dest >= 0 else { throw CollectorSQLiteSnapshotError.unavailable }
        defer { Darwin.close(dest) }
        var offset: off_t = 0
        var remaining = expectedSize
        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            try clock.check()
            let want = Int(min(Int64(buffer.count), remaining))
            let got = buffer.withUnsafeMutableBytes { pread(source, $0.baseAddress, want, offset) }
            guard got > 0 else { throw CollectorSQLiteSnapshotError.unavailable }
            let wrote = buffer.withUnsafeBytes { pwrite(dest, $0.baseAddress, got, offset) }
            guard wrote == got else { throw CollectorSQLiteSnapshotError.unavailable }
            offset += off_t(got)
            remaining -= off_t(got)
            copied += Int64(got)
        }
        try verifyStagedFile(directory, name, expectedSize: expectedSize)
        return copied
    }

    private static func verifyStagedFile(_ directory: Int32, _ name: String, expectedSize: off_t) throws {
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CollectorSQLiteSnapshotError.unavailable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == expectedSize, (info.st_mode & 0o777) == 0o600 else {
            throw CollectorSQLiteSnapshotError.unavailable
        }
    }

    private static func generation(from info: stat) throws -> ArchiveSourceGeneration {
        guard (info.st_mode & S_IFMT) == S_IFREG, let inode = Int64(exactly: info.st_ino) else {
            throw CollectorSQLiteSnapshotError.unavailable
        }
        return try ArchiveSourceGeneration(
            device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
            mtimeNs: nanoseconds(info.st_mtimespec), ctimeNs: nanoseconds(info.st_ctimespec),
            mode: Int64(info.st_mode)
        )
    }

    private static func nanoseconds(_ value: timespec) throws -> Int64 {
        let seconds = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let nanos = seconds.partialValue.addingReportingOverflow(Int64(value.tv_nsec))
        guard !seconds.overflow, !nanos.overflow else { throw CollectorSQLiteSnapshotError.unavailable }
        return nanos.partialValue
    }

}

private final class SnapshotLifetime {
    var active = true
}

private final class SourceFD {
    var fd: Int32
    var info: stat

    init(fd: Int32, info: stat) {
        self.fd = fd
        self.info = info
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

private struct OwnedStaging {
    let databaseName: String
    var parentFD: Int32
    var childFD: Int32
    var childName: String
    var parentDev: dev_t
    var parentIno: ino_t
    var childDev: dev_t
    var childIno: ino_t
    var mainGeneration: ArchiveSourceGeneration?
    var walGeneration: ArchiveSourceGeneration?
}

private struct OpenedRoot {
    let url: URL
    let descriptor: Int32
    let info: stat
}

private final class LeaseClock {
    let deadline: UInt64

    init(milliseconds: Int) throws {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now != 0 else { throw CollectorSQLiteSnapshotError.unavailable }
        let add = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        let sum = now.addingReportingOverflow(add.partialValue)
        guard !add.overflow, !sum.overflow else { throw CollectorSQLiteSnapshotError.exceededBudget }
        deadline = sum.partialValue
    }

    var expired: Bool {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > deadline
    }

    func check() throws {
        try Task.checkCancellation()
        if expired { throw CollectorSQLiteSnapshotError.exceededBudget }
    }
}

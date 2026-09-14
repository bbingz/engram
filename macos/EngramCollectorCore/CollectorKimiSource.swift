import CryptoKit
import Darwin
import Foundation

/// Metadata-only dependency observation; transcript parsing remains on HQ.
enum CollectorKimiSource {
    static let maximumRegistryBytes = 65_536
    static let maximumDirectoryEntries = 4096

    private static let primaryName = "context.jsonl"
    private static let wireName = "wire.jsonl"

    static func isSelectedPrimary(rootPath: String, components: [String]) -> Bool {
        _ = rootPath
        guard components.count == 3, components[2] == primaryName,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            return false
        }
        return true
    }

    static func owningPrimary(rootPath: String, dirtyRelative: String) -> String? {
        owningCandidates(rootPath: rootPath, dirtyRelative: dirtyRelative).first
    }

    static func owningCandidates(rootPath: String, dirtyRelative: String) -> [String] {
        _ = rootPath
        let parts = dirtyRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let name = parts.last else { return [] }
        if name == primaryName { return [dirtyRelative] }
        if name == wireName || contextShardIdentity(name) != nil {
            return [parts[0] + "/" + parts[1] + "/" + primaryName]
        }
        return []
    }

    static func sessionOwning(_ relative: String) -> String? {
        owningPrimary(rootPath: "", dirtyRelative: relative)
    }

    static func membershipEquals(_ lhs: CollectorDependencySnapshot, _ rhs: CollectorDependencySnapshot) -> Bool {
        lhs.present == rhs.present && lhs.absentRelativePaths == rhs.absentRelativePaths
    }

    static func provenanceEquals(_ lhs: CollectorDependencySnapshot, _ rhs: CollectorDependencySnapshot) -> Bool {
        membershipEquals(lhs, rhs)
            && lhs.entrypointRelativePath.utf8.elementsEqual(rhs.entrypointRelativePath.utf8)
            && lhs.kimiProjectContext == rhs.kimiProjectContext
            && lhs.geminiProjectContext == nil && rhs.geminiProjectContext == nil
    }

    struct Context: Equatable, Sendable {
        let workspaceName: String
        let nativeSessionID: String
        let cwd: String
        let registryLocator: String
        let registryGeneration: ArchiveSourceGeneration
        let registrySHA256: String
        let scopedRegistryBytes: Data
    }

    struct Observation: Equatable, Sendable {
        let generation: ArchiveSourceGeneration
        let snapshot: CollectorDependencySnapshot
        let context: Context
    }

    static func observe(
        rootPath: String, primaryRelative: String, registryLocator: String,
        beforeFinalValidation: (() throws -> Void)? = nil
    ) throws -> Observation {
        try Task.checkCancellation()
        let first = try observeOnce(
            rootPath: rootPath, primaryRelative: primaryRelative, registryLocator: registryLocator
        )
        try beforeFinalValidation?()
        let second = try observeOnce(
            rootPath: rootPath, primaryRelative: primaryRelative, registryLocator: registryLocator
        )
        guard first.rootIdentity == second.rootIdentity,
              first.sessionIdentity == second.sessionIdentity,
              first.observation == second.observation else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return first.observation
    }

    private struct Observed {
        let observation: Observation
        let rootIdentity: CollectorPOSIXDirectoryIdentity
        let sessionIdentity: CollectorPOSIXDirectoryIdentity
    }

    private static func observeOnce(
        rootPath: String, primaryRelative: String, registryLocator: String
    ) throws -> Observed {
        try Task.checkCancellation()
        let parts = try primaryParts(primaryRelative)
        let workspace = parts[0]
        let session = parts[1]
        let root = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        )
        defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
        let rootIdentity = try CollectorPOSIXDirectoryAccess.identity(root.info)
        let workspaceFd = try CollectorPOSIXDirectoryAccess.openComponent(workspace, parent: root.descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(workspaceFd) }
        let sessionFd = try CollectorPOSIXDirectoryAccess.openComponent(session, parent: workspaceFd)
        defer { CollectorPOSIXDirectoryAccess.close(sessionFd) }
        let sessionIdentity = try CollectorPOSIXDirectoryAccess.identity(
            try CollectorPOSIXDirectoryAccess.directoryStat(sessionFd)
        )
        let prefix = workspace + "/" + session + "/"
        guard let primaryGeneration = try statRegularFile(parent: sessionFd, name: primaryName) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let members = try listSessionMembers(sessionFd: sessionFd, prefix: prefix, primaryGeneration: primaryGeneration)
        try requireValidSnapshot(members, primaryRelative: primaryRelative)
        guard try CollectorPOSIXDirectoryAccess.identity(
                  try CollectorPOSIXDirectoryAccess.directoryStat(root.descriptor)
              ) == rootIdentity,
              try CollectorPOSIXDirectoryAccess.identity(
                  try CollectorPOSIXDirectoryAccess.directoryStat(sessionFd)
              ) == sessionIdentity,
              try statRegularFile(parent: sessionFd, name: primaryName) == primaryGeneration else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let context = try observeRegistry(
            locator: registryLocator, workspaceName: workspace, nativeSessionID: session
        )
        let snapshot = CollectorDependencySnapshot(
            entrypointRelativePath: primaryRelative,
            present: members.present,
            absentRelativePaths: members.absent,
            kimiProjectContext: try ArchiveKimiProjectContext(
                workspaceName: context.workspaceName, nativeSessionID: context.nativeSessionID,
                cwd: context.cwd, registryLocator: context.registryLocator,
                registryGeneration: context.registryGeneration, registrySHA256: context.registrySHA256)
        )
        try requireValidSnapshot(snapshot, entrypoint: primaryRelative)
        return Observed(
            observation: Observation(generation: primaryGeneration, snapshot: snapshot, context: context),
            rootIdentity: rootIdentity,
            sessionIdentity: sessionIdentity
        )
    }

    private static func primaryParts(_ relative: String) throws -> [String] {
        guard CollectorInventoryStore.isSafeRelativePath(relative) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2] == primaryName else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return parts
    }

    private struct SessionMembers {
        let present: [CollectorDependencySnapshot.PresentMember]
        let absent: [String]
    }

    private static func listSessionMembers(
        sessionFd: Int32, prefix: String, primaryGeneration: ArchiveSourceGeneration
    ) throws -> SessionMembers {
        let duplicated = dup(sessionFd)
        guard duplicated >= 0 else { throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno) }
        guard let stream = fdopendir(duplicated) else {
            _ = Darwin.close(duplicated)
            throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno)
        }
        defer { closedir(stream) }
        var present: [CollectorDependencySnapshot.PresentMember] = [
            .init(relativePath: prefix + primaryName, generation: primaryGeneration)
        ]
        var shardIdentities = Set<ShardIdentity>()
        var sawPrimary = false
        var sawWire = false
        var entries = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw CollectorPOSIXEnumerationError.io(.readDirectory, errno) }
                break
            }
            var value = entry.pointee
            let count = Int(value.d_namlen)
            let name: String = try withUnsafeBytes(of: &value.d_name) { buffer in
                guard count > 0, count < buffer.count, buffer[count] == 0,
                      let decoded = String(bytes: buffer.prefix(count), encoding: .utf8) else {
                    throw CollectorPOSIXEnumerationError.invalidEntryName
                }
                return decoded
            }
            if name == "." || name == ".." { continue }
            entries += 1
            guard entries <= maximumDirectoryEntries else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            if name == primaryName {
                guard try statRegularFile(parent: sessionFd, name: name) == primaryGeneration else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                sawPrimary = true
                continue
            }
            if name == wireName {
                guard let generation = try statRegularFile(parent: sessionFd, name: name) else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                present.append(.init(relativePath: prefix + name, generation: generation))
                sawWire = true
                continue
            }
            if let identity = contextShardIdentity(name) {
                guard shardIdentities.insert(identity).inserted,
                      let generation = try statRegularFile(parent: sessionFd, name: name) else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                present.append(.init(relativePath: prefix + name, generation: generation))
            }
        }
        guard sawPrimary else { throw CollectorPublicationWorkerError.invalidCapture }
        var absent: [String] = []
        if !sawWire {
            if try statRegularFile(parent: sessionFd, name: wireName) != nil {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            absent.append(prefix + wireName)
        }
        present.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        absent.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return SessionMembers(present: present, absent: absent)
    }

    static func requireValidSnapshot(_ snapshot: CollectorDependencySnapshot, entrypoint: String) throws {
        guard snapshot.entrypointRelativePath.utf8.elementsEqual(entrypoint.utf8),
              snapshot.geminiProjectContext == nil,
              let context = snapshot.kimiProjectContext else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        do {
            var cursor: Int64 = 0
            var files: [ArchiveFileSetEntry] = []
            files.reserveCapacity(snapshot.present.count)
            for member in snapshot.present {
                let digest = member.generation.size == 0
                    ? ArchiveV2Hash.sha256(Data())
                    : String(repeating: "a", count: 64)
                files.append(try ArchiveFileSetEntry(
                    relativePath: member.relativePath,
                    byteOffset: cursor,
                    rawByteCount: member.generation.size,
                    wholeSourceSHA256: digest,
                    generation: member.generation
                ))
                let (next, overflow) = cursor.addingReportingOverflow(member.generation.size)
                guard !overflow else { throw CollectorPublicationWorkerError.invalidCapture }
                cursor = next
            }
            _ = try ArchiveReplayLayout(
                strategy: .fileSet,
                relativePaths: snapshot.present.map(\.relativePath),
                entrypointRelativePath: entrypoint,
                files: files,
                absentRelativePaths: snapshot.absentRelativePaths,
                kimiProjectContext: context
            )
        } catch {
            throw CollectorPublicationWorkerError.invalidCapture
        }
    }

    static func matchesReservedSnapshot(
        _ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest
    ) -> Bool {
        guard ArchiveSourceDescriptor.isKimiFileSet(manifest),
              manifest.schemaVersion == 5,
              manifest.replayLayout.strategy == .fileSet,
              let files = manifest.replayLayout.files,
              let absent = manifest.replayLayout.absentRelativePaths,
              let entrypoint = manifest.replayLayout.entrypointRelativePath,
              entrypoint.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8),
              files.count == snapshot.present.count,
              absent.count == snapshot.absentRelativePaths.count,
              snapshot.geminiProjectContext == nil,
              manifest.replayLayout.geminiProjectContext == nil,
              manifest.replayLayout.sqliteSession == nil,
              snapshot.kimiProjectContext == manifest.replayLayout.kimiProjectContext else {
            return false
        }
        for (file, member) in zip(files, snapshot.present) {
            guard file.relativePath.utf8.elementsEqual(member.relativePath.utf8),
                  file.generation == member.generation else {
                return false
            }
        }
        for (path, expected) in zip(absent, snapshot.absentRelativePaths) {
            guard path.utf8.elementsEqual(expected.utf8) else { return false }
        }
        return (try? requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)) != nil
    }

    private static func requireValidSnapshot(_ members: SessionMembers, primaryRelative: String) throws {
        let declared = members.present.count + members.absent.count
        guard declared <= ArchiveReplayLayout.maximumFileSetDependencies,
              members.present.contains(where: { $0.relativePath.utf8.elementsEqual(primaryRelative.utf8) }),
              Set(members.present.map(\.relativePath) + members.absent).count == declared else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        for (previous, next) in zip(members.present, members.present.dropFirst()) {
            guard previous.relativePath.utf8.lexicographicallyPrecedes(next.relativePath.utf8) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
    }

    private struct ShardIdentity: Hashable {
        let family: String
        let index: Int
    }

    private static func contextShardIdentity(_ filename: String) -> ShardIdentity? {
        guard filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropLast(".jsonl".count))
        if stem.hasPrefix("context_sub_") {
            guard let index = Int(stem.dropFirst("context_sub_".count)) else { return nil }
            return ShardIdentity(family: "context_sub", index: index)
        }
        if stem.hasPrefix("context_") {
            guard let index = Int(stem.dropFirst("context_".count)) else { return nil }
            return ShardIdentity(family: "context", index: index)
        }
        return nil
    }

    private static func observeRegistry(
        locator: String, workspaceName: String, nativeSessionID: String
    ) throws -> Context {
        try Task.checkCancellation()
        guard let normalized = ArchiveSourceDescriptor.fileSetAbsolutePath(locator),
              normalized.utf8.elementsEqual(locator.utf8) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = try CollectorPOSIXDirectoryAccess.components(locator)
        guard parts.count >= 1 else { throw CollectorPublicationWorkerError.invalidCapture }
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: Array(parts.dropLast()))
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        let name = parts[parts.count - 1]
        let descriptor = name.withCString { openat(opened.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw CollectorPublicationWorkerError.invalidCapture }
        defer { _ = Darwin.close(descriptor) }
        var openedInfo = stat()
        var namedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              name.withCString({ fstatat(opened.descriptor, $0, &namedInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
              openedInfo.st_dev == namedInfo.st_dev, openedInfo.st_ino == namedInfo.st_ino,
              openedInfo.st_mode & S_IFMT == S_IFREG,
              openedInfo.st_size >= 0, openedInfo.st_size <= maximumRegistryBytes else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let generation = try generation(from: openedInfo)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: min(Int(openedInfo.st_size), 4096))
        while bytes.count < Int(openedInfo.st_size) {
            try Task.checkCancellation()
            let want = min(buffer.count, Int(openedInfo.st_size) - bytes.count)
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, want) }
            if readCount == 0 { break }
            if readCount < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            bytes.append(contentsOf: buffer.prefix(readCount))
        }
        var after = stat()
        var namedAfter = stat()
        guard fstat(descriptor, &after) == 0,
              name.withCString({ fstatat(opened.descriptor, $0, &namedAfter, AT_SYMLINK_NOFOLLOW) }) == 0,
              after.st_dev == namedAfter.st_dev, after.st_ino == namedAfter.st_ino,
              try Self.generation(from: after) == generation,
              bytes.count == Int(generation.size) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let selected = try selectWorkDir(bytes: bytes, workspaceName: workspaceName, nativeSessionID: nativeSessionID)
        return Context(
            workspaceName: workspaceName,
            nativeSessionID: nativeSessionID,
            cwd: selected.cwd,
            registryLocator: locator,
            registryGeneration: generation,
            registrySHA256: ArchiveV2Hash.sha256(bytes),
            scopedRegistryBytes: selected.scoped
        )
    }

    private static func selectWorkDir(
        bytes: Data, workspaceName: String, nativeSessionID: String
    ) throws -> (cwd: String, scoped: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let rows = object["work_dirs"] as? [Any] else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        var parsed: [[String: String]] = []
        parsed.reserveCapacity(rows.count)
        for row in rows {
            guard let values = row as? [String: Any] else { continue }
            var mapped: [String: String] = [:]
            if let path = values["path"] as? String { mapped["path"] = path }
            if let kaos = values["kaos"] as? String { mapped["kaos"] = kaos }
            if let session = values["last_session_id"] as? String { mapped["last_session_id"] = session }
            parsed.append(mapped)
        }
        let hashHits = parsed.filter {
            guard let path = $0["path"] else { return false }
            return workspaceDirectoryName(path: path, kaos: $0["kaos"]).utf8.elementsEqual(workspaceName.utf8)
        }
        let selected: [String: String]
        if hashHits.count > 1 {
            throw CollectorPublicationWorkerError.invalidCapture
        } else if hashHits.count == 1 {
            selected = hashHits[0]
        } else {
            let fallback = parsed.filter { ($0["last_session_id"] ?? "").utf8.elementsEqual(nativeSessionID.utf8) }
            guard fallback.count == 1 else { throw CollectorPublicationWorkerError.invalidCapture }
            selected = fallback[0]
        }
        guard let cwd = selected["path"], cwd.hasPrefix("/"), !cwd.utf8.contains(0), cwd.utf8.count <= 4096 else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        var scopedRow: [String: String] = ["path": cwd]
        if let kaos = selected["kaos"], !kaos.isEmpty { scopedRow["kaos"] = kaos }
        if hashHits.isEmpty { scopedRow["last_session_id"] = nativeSessionID }
        guard let scoped = try? JSONSerialization.data(
            withJSONObject: ["work_dirs": [scopedRow]], options: [.sortedKeys]
        ) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return (cwd, scoped)
    }

    private static func workspaceDirectoryName(path: String, kaos: String?) -> String {
        let digest = Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let kaos, !kaos.isEmpty, kaos != "local" else { return digest }
        return "\(kaos)_\(digest)"
    }

    private static func statRegularFile(parent: Int32, name: String) throws -> ArchiveSourceGeneration? {
        try Task.checkCancellation()
        var info = stat()
        let result = name.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw CollectorPOSIXEnumerationError.io(.statEntry, errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return try generation(from: info)
    }

    private static func generation(from info: stat) throws -> ArchiveSourceGeneration {
        guard let inode = Int64(exactly: info.st_ino) else {
            throw CollectorPOSIXEnumerationError.io(.statEntry, EOVERFLOW)
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
        guard !seconds.overflow, !nanos.overflow else {
            throw CollectorPOSIXEnumerationError.io(.statEntry, EOVERFLOW)
        }
        return nanos.partialValue
    }
}

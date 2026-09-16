import Darwin
import Foundation

/// Metadata-only Grok file-set observation. Transcript parsing remains on HQ.
enum CollectorGrokSource {
    static let memberNames = ["chat_history.jsonl", "updates.jsonl", "summary.json", "prompt_context.json"]
    static let primaryNames = ["chat_history.jsonl", "updates.jsonl", "summary.json"]
    private static let compactionDirectory = "compaction"
    private static let compactionIndexName = "INDEX.md"

    static func isPrimaryCandidate(components: [String]) -> Bool {
        guard components.count == 3, let name = components.last, isPrimaryName(name) else { return false }
        return components.allSatisfy(isSafeComponent)
    }

    /// Preferred existing regular primary only. A symlink/fifo at a higher
    /// preference is rejection, not fallback, so one session cannot emit two
    /// selected locators.
    static func isSelectedPrimary(rootPath: String, components: [String]) -> Bool {
        guard isPrimaryCandidate(components: components), !rootPath.isEmpty,
              let preferred = preferredPrimary(rootPath: rootPath, project: components[0], session: components[1]),
              let name = components.last else { return false }
        return URL(fileURLWithPath: preferred).lastPathComponent.utf8.elementsEqual(name.utf8)
    }

    static func owningPrimary(rootPath: String, dirtyRelative: String) -> String? {
        owningCandidates(rootPath: rootPath, dirtyRelative: dirtyRelative).first
    }

    static func owningCandidates(rootPath: String, dirtyRelative: String) -> [String] {
        guard let session = sessionOwning(dirtyRelative) else { return [] }
        let split = session.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard split.count == 2 else { return [] }
        return preferredPrimary(rootPath: rootPath, project: split[0], session: split[1]).map { [$0] } ?? []
    }

    static func sessionOwning(_ relative: String) -> String? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0...1].allSatisfy(isSafeComponent) else { return nil }
        if parts.count == 3, isKnownMember(parts[2]) {
            return parts[0] + "/" + parts[1]
        }
        guard parts.count == 4, isCompactionDirectory(parts[2]), isCompactionFile(parts[3]) else {
            return nil
        }
        return parts[0] + "/" + parts[1]
    }

    static func observe(
        rootPath: String, primaryRelative: String
    ) throws -> (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot) {
        try Task.checkCancellation()
        let parts = try sessionParts(primaryRelative)
        let project = parts[0]
        let session = parts[1]
        let root = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        )
        defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
        let projectFd = try CollectorPOSIXDirectoryAccess.openComponent(project, parent: root.descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(projectFd) }
        let sessionFd = try CollectorPOSIXDirectoryAccess.openComponent(session, parent: projectFd)
        defer { CollectorPOSIXDirectoryAccess.close(sessionFd) }
        let prefix = project + "/" + session + "/"
        var present: [CollectorDependencySnapshot.PresentMember] = []
        var absent: [String] = []
        for name in memberNames {
            try consider(name: name, relative: prefix + name, parent: sessionFd, present: &present, absent: &absent)
        }
        try considerCompaction(prefix: prefix, sessionFd: sessionFd, present: &present, absent: &absent)
        // Presence is metadata-only. Auxiliary members may exceed 100MiB
        // (daily max updates.jsonl is 278611574 B); the primary parser bound
        // is applied later and must not shrink this closed set.
        present.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        absent.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard let entrypoint = preferredPrimary(present: present.map(\.relativePath)),
              let generation = present.first(where: { $0.relativePath.utf8.elementsEqual(entrypoint.utf8) })?.generation
        else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let snapshot = CollectorDependencySnapshot(
            entrypointRelativePath: entrypoint, present: present, absentRelativePaths: absent
        )
        try requireValidSnapshot(snapshot, entrypoint: entrypoint)
        return (generation, snapshot)
    }

    static func membershipEquals(_ lhs: CollectorDependencySnapshot, _ rhs: CollectorDependencySnapshot) -> Bool {
        lhs.present == rhs.present && lhs.absentRelativePaths == rhs.absentRelativePaths
    }

    static func provenanceEquals(_ lhs: CollectorDependencySnapshot, _ rhs: CollectorDependencySnapshot) -> Bool {
        membershipEquals(lhs, rhs)
            && lhs.entrypointRelativePath.utf8.elementsEqual(rhs.entrypointRelativePath.utf8)
            && lhs.geminiProjectContext == nil && rhs.geminiProjectContext == nil
            && lhs.kimiProjectContext == nil && rhs.kimiProjectContext == nil
            && lhs.vscodeWorkspaceContext == nil && rhs.vscodeWorkspaceContext == nil
    }

    static func matchesReservedSnapshot(
        _ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest
    ) -> Bool {
        guard ArchiveSourceDescriptor.isGrokFileSet(manifest),
              manifest.replayLayout.strategy == .fileSet,
              let files = manifest.replayLayout.files,
              let absent = manifest.replayLayout.absentRelativePaths,
              let entrypoint = manifest.replayLayout.entrypointRelativePath,
              entrypoint.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8),
              files.count == snapshot.present.count,
              absent.count == snapshot.absentRelativePaths.count,
              snapshot.geminiProjectContext == nil,
              snapshot.kimiProjectContext == nil,
              snapshot.vscodeWorkspaceContext == nil,
              manifest.schemaVersion == 2 else {
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
        return true
    }

    static func requireValidSnapshot(_ snapshot: CollectorDependencySnapshot, entrypoint: String) throws {
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard snapshot.geminiProjectContext == nil, snapshot.kimiProjectContext == nil,
              snapshot.vscodeWorkspaceContext == nil,
              snapshot.entrypointRelativePath.utf8.elementsEqual(entrypoint.utf8),
              isPrimaryCandidate(components: parts),
              let preferred = preferredPrimary(present: snapshot.present.map(\.relativePath)),
              preferred.utf8.elementsEqual(entrypoint.utf8),
              snapshot.present.contains(where: { $0.relativePath.utf8.elementsEqual(entrypoint.utf8) }) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let declared = snapshot.present.map(\.relativePath) + snapshot.absentRelativePaths
        let core = memberNames.map { parts[0] + "/" + parts[1] + "/" + $0 }
        let index = compactionIndexPath(project: parts[0], session: parts[1])
        guard declared.count <= ArchiveReplayLayout.maximumFileSetDependencies,
              declared.count == Set(declared).count,
              core.allSatisfy({ path in declared.contains { $0.utf8.elementsEqual(path.utf8) } }),
              declared.contains(where: { $0.utf8.elementsEqual(index.utf8) }) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        for path in declared {
            guard isDeclaredMember(path, project: parts[0], session: parts[1]) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            let member = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if member.count == 4, isCompactionSegmentName(member[3]),
               !snapshot.present.contains(where: { $0.relativePath.utf8.elementsEqual(path.utf8) }) {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
        for (previous, next) in zip(snapshot.present, snapshot.present.dropFirst()) {
            guard previous.relativePath.utf8.lexicographicallyPrecedes(next.relativePath.utf8) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
        for (previous, next) in zip(snapshot.absentRelativePaths, snapshot.absentRelativePaths.dropFirst()) {
            guard previous.utf8.lexicographicallyPrecedes(next.utf8) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
    }

    static func decodedProjectDirectory(_ project: String) -> String? {
        project.removingPercentEncoding
    }

    static func nativeSessionID(fromSummary object: [String: Any]?, sessionDirectory: String) -> String? {
        if let info = object?["info"] as? [String: Any], let id = string(info["id"]) { return id }
        return sessionDirectory.isEmpty ? nil : sessionDirectory
    }

    static func projectCWD(
        summary: [String: Any]?, promptContext: [String: Any]?, project: String
    ) -> String? {
        if let info = summary?["info"] as? [String: Any], let cwd = string(info["cwd"]) { return cwd }
        if let cwd = string(promptContext?["working_directory"]) { return cwd }
        return decodedProjectDirectory(project)
    }

    static func jsonObject(from bytes: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    }

    private static func preferredPrimary(rootPath: String, project: String, session: String) -> String? {
        guard !rootPath.isEmpty else { return nil }
        let prefix = project + "/" + session + "/"
        guard let opened = try? CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        ) else { return nil }
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        guard let projectFd = try? CollectorPOSIXDirectoryAccess.openComponent(project, parent: opened.descriptor) else {
            return nil
        }
        defer { CollectorPOSIXDirectoryAccess.close(projectFd) }
        guard let sessionFd = try? CollectorPOSIXDirectoryAccess.openComponent(session, parent: projectFd) else {
            return nil
        }
        defer { CollectorPOSIXDirectoryAccess.close(sessionFd) }
        for name in primaryNames {
            switch (try? inspectFile(parent: sessionFd, name: name)) ?? .unsafe {
            case .missing:
                continue
            case .unsafe:
                return nil
            case .regular:
                return prefix + name
            }
        }
        return nil
    }

    private static func preferredPrimary(present: [String]) -> String? {
        for name in primaryNames {
            if let path = present.first(where: { URL(fileURLWithPath: $0).lastPathComponent.utf8.elementsEqual(name.utf8) }) {
                return path
            }
        }
        return nil
    }

    private static func sessionParts(_ relative: String) throws -> [String] {
        guard CollectorInventoryStore.isSafeRelativePath(relative) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, isKnownMember(parts[2]), isSafeComponent(parts[0]), isSafeComponent(parts[1]) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return parts
    }

    private static func isKnownMember(_ name: String) -> Bool {
        memberNames.contains { $0.utf8.elementsEqual(name.utf8) }
    }

    private static func isPrimaryName(_ name: String) -> Bool {
        primaryNames.contains { $0.utf8.elementsEqual(name.utf8) }
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
    }

    private static func isCompactionDirectory(_ name: String) -> Bool {
        name.utf8.elementsEqual(compactionDirectory.utf8)
    }

    private static func isCompactionFile(_ name: String) -> Bool {
        name.utf8.elementsEqual(compactionIndexName.utf8) || isCompactionSegmentName(name)
    }

    private static func isCompactionSegmentName(_ name: String) -> Bool {
        guard name.hasPrefix("segment_"), name.hasSuffix(".md"), isSafeComponent(name) else { return false }
        let stem = String(name.dropFirst("segment_".count).dropLast(".md".count))
        return !stem.isEmpty && isSafeComponent(stem)
    }

    private static func compactionIndexPath(project: String, session: String) -> String {
        project + "/" + session + "/" + compactionDirectory + "/" + compactionIndexName
    }

    private static func isDeclaredMember(_ path: String, project: String, session: String) -> Bool {
        let member = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard member.count >= 3, member[0].utf8.elementsEqual(project.utf8),
              member[1].utf8.elementsEqual(session.utf8), member.allSatisfy(isSafeComponent) else {
            return false
        }
        if member.count == 3 { return isKnownMember(member[2]) }
        return member.count == 4 && isCompactionDirectory(member[2]) && isCompactionFile(member[3])
    }

    private static func considerCompaction(
        prefix: String, sessionFd: Int32,
        present: inout [CollectorDependencySnapshot.PresentMember], absent: inout [String]
    ) throws {
        let index = prefix + compactionDirectory + "/" + compactionIndexName
        do {
            let compactionFd = try CollectorPOSIXDirectoryAccess.openComponent(
                compactionDirectory, parent: sessionFd
            )
            defer { CollectorPOSIXDirectoryAccess.close(compactionFd) }
            try consider(name: compactionIndexName, relative: index, parent: compactionFd, present: &present, absent: &absent)
            for body in try listRegularSegments(directory: compactionFd) {
                present.append(
                    .init(relativePath: prefix + compactionDirectory + "/" + body.name, generation: body.generation)
                )
            }
        } catch let error as CollectorPOSIXEnumerationError {
            if case .io(.openComponent, let code) = error, code == ENOENT {
                absent.append(index)
            } else {
                throw error
            }
        }
    }

    private static func listRegularSegments(
        directory fd: Int32
    ) throws -> [(name: String, generation: ArchiveSourceGeneration)] {
        let duplicated = dup(fd)
        guard duplicated >= 0 else { throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno) }
        guard let stream = fdopendir(duplicated) else {
            _ = Darwin.close(duplicated)
            throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno)
        }
        defer { closedir(stream) }
        var result: [(name: String, generation: ArchiveSourceGeneration)] = []
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
            if name == "." || name == ".." || !isCompactionSegmentName(name) { continue }
            switch try inspectFile(parent: fd, name: name) {
            case .missing:
                continue
            case .regular(let generation):
                result.append((name, generation))
            case .unsafe:
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
        return result
    }

    private enum FilePresence {
        case missing
        case regular(ArchiveSourceGeneration)
        case unsafe
    }

    private static func consider(
        name: String, relative: String, parent: Int32,
        present: inout [CollectorDependencySnapshot.PresentMember], absent: inout [String]
    ) throws {
        switch try inspectFile(parent: parent, name: name) {
        case .missing:
            absent.append(relative)
        case .regular(let generation):
            present.append(.init(relativePath: relative, generation: generation))
        case .unsafe:
            throw CollectorPublicationWorkerError.invalidCapture
        }
    }

    private static func inspectFile(parent: Int32, name: String) throws -> FilePresence {
        try Task.checkCancellation()
        var info = stat()
        let result = name.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return .missing }
            throw CollectorPOSIXEnumerationError.io(.statEntry, errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unsafe }
        return .regular(try generation(from: info))
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

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

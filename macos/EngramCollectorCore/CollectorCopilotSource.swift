import Darwin
import Foundation

enum CollectorCopilotSource {
    static let maximumConversationSniffBytes = 65_536
    static let maximumConversationSniffLineBytes = 1_048_576
    static let maximumIndexSniffBytes = 65_536

    private static let eventsName = "events.jsonl"
    private static let workspaceName = "workspace.yaml"
    private static let checkpointsDirectory = "checkpoints"
    private static let indexName = "index.md"

    static func isSelectedPrimary(rootPath: String, components: [String]) -> Bool {
        _ = rootPath
        guard let session = components.first, !session.hasPrefix("."),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if components.count == 2, components[1] == eventsName { return true }
        if components.count == 3, components[1] == checkpointsDirectory, components[2] == indexName { return true }
        return false
    }

    static func owningPrimary(rootPath: String, dirtyRelative: String) -> String? {
        owningCandidates(rootPath: rootPath, dirtyRelative: dirtyRelative).first
    }

    static func owningCandidates(rootPath: String, dirtyRelative: String) -> [String] {
        let parts = dirtyRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard isSessionMember(parts), let session = parts.first else { return [] }
        var result: [String] = []
        let events = session + "/" + eventsName
        if regularFileExists(rootPath: rootPath, relative: events) { result.append(events) }
        let index = session + "/" + checkpointsDirectory + "/" + indexName
        if regularFileExists(rootPath: rootPath, relative: index) { result.append(index) }
        return result
    }

    static func sessionOwning(_ relative: String) -> String? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let session = parts.first, !session.isEmpty, session != ".", session != "..",
              !session.hasPrefix(".") else { return nil }
        return session
    }

    static func membershipEquals(_ lhs: CollectorDependencySnapshot, _ rhs: CollectorDependencySnapshot) -> Bool {
        lhs.present == rhs.present && lhs.absentRelativePaths == rhs.absentRelativePaths
    }

    static func preferredEntrypoint(
        rootPath: String, snapshot: CollectorDependencySnapshot, maximumByteCount: Int64
    ) throws -> String? {
        try Task.checkCancellation()
        guard maximumByteCount > 0,
              let session = sessionOwning(snapshot.entrypointRelativePath) else { return nil }
        let events = session + "/" + eventsName
        let index = session + "/" + checkpointsDirectory + "/" + indexName
        if let member = snapshot.present.first(where: { $0.relativePath.utf8.elementsEqual(events.utf8) }) {
            switch try sniffConversation(
                rootPath: rootPath, relative: events, expected: member.generation, maximumByteCount: maximumByteCount
            ) {
            case .found: return events
            case .absent: break
            case .truncated, .changed: return nil
            }
        }
        if let member = snapshot.present.first(where: { $0.relativePath.utf8.elementsEqual(index.utf8) }) {
            switch try sniffIndexRow(
                rootPath: rootPath, relative: index, expected: member.generation, maximumByteCount: maximumByteCount
            ) {
            case .found: return index
            case .absent, .truncated, .changed: return nil
            }
        }
        return nil
    }

    static func observe(
        rootPath: String, primaryRelative: String
    ) throws -> (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot) {
        try Task.checkCancellation()
        guard CollectorInventoryStore.isSafeRelativePath(primaryRelative),
              let session = sessionName(fromPrimary: primaryRelative) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let slots = canonicalSlots(session: session)
        guard primaryRelative.utf8.elementsEqual(slots.events.utf8)
            || primaryRelative.utf8.elementsEqual(slots.index.utf8) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let root = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        )
        defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
        let sessionFd = try CollectorPOSIXDirectoryAccess.openComponent(session, parent: root.descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(sessionFd) }

        var present: [CollectorDependencySnapshot.PresentMember] = []
        var absent: [String] = []
        try consider(name: eventsName, relative: slots.events, parent: sessionFd, present: &present, absent: &absent)
        try consider(name: workspaceName, relative: slots.workspace, parent: sessionFd, present: &present, absent: &absent)

        do {
            let checkpoints = try CollectorPOSIXDirectoryAccess.openComponent(
                checkpointsDirectory, parent: sessionFd
            )
            defer { CollectorPOSIXDirectoryAccess.close(checkpoints) }
            try consider(name: indexName, relative: slots.index, parent: checkpoints, present: &present, absent: &absent)
            for body in try listRegularMarkdown(directory: checkpoints) where body.name != indexName {
                present.append(
                    .init(
                        relativePath: session + "/" + checkpointsDirectory + "/" + body.name,
                        generation: body.generation
                    )
                )
            }
        } catch let error as CollectorPOSIXEnumerationError {
            if case .io(.openComponent, let code) = error, code == ENOENT {
                absent.append(slots.index)
            } else {
                throw error
            }
        }

        present.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        absent.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let snapshot = CollectorDependencySnapshot(
            entrypointRelativePath: primaryRelative, present: present, absentRelativePaths: absent
        )
        try requireValidSnapshot(snapshot, entrypoint: primaryRelative)
        guard let primary = present.first(where: { $0.relativePath.utf8.elementsEqual(primaryRelative.utf8) }) else {
            throw POSIXError(.ENOENT)
        }
        return (primary.generation, snapshot)
    }

    static func matchesReservedSnapshot(
        _ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest
    ) -> Bool {
        guard manifest.replayLayout.strategy == .fileSet,
              let files = manifest.replayLayout.files,
              let absent = manifest.replayLayout.absentRelativePaths,
              let entrypoint = manifest.replayLayout.entrypointRelativePath,
              entrypoint.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8),
              files.count == snapshot.present.count,
              absent.count == snapshot.absentRelativePaths.count,
              snapshot.geminiProjectContext == nil,
              manifest.replayLayout.geminiProjectContext == nil else {
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

    static func parseWorkspace(bytes: Data) -> [String: String] {
        guard let content = String(data: bytes, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            guard key.range(of: #"^\w+$"#, options: .regularExpression) != nil else { continue }
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            result[key] = stripYAMLQuotes(value)
        }
        return result
    }

    static func requireValidSnapshot(_ snapshot: CollectorDependencySnapshot, entrypoint: String) throws {
        guard snapshot.geminiProjectContext == nil,
              snapshot.entrypointRelativePath.utf8.elementsEqual(entrypoint.utf8),
              let session = sessionName(fromPrimary: entrypoint) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let slots = canonicalSlots(session: session)
        let declared = snapshot.present.map(\.relativePath) + snapshot.absentRelativePaths
        guard declared.count == Set(declared).count,
              declared.count <= ArchiveReplayLayout.maximumFileSetDependencies,
              snapshot.present.contains(where: { $0.relativePath.utf8.elementsEqual(entrypoint.utf8) }),
              declared.contains(where: { $0.utf8.elementsEqual(slots.events.utf8) }),
              declared.contains(where: { $0.utf8.elementsEqual(slots.workspace.utf8) }),
              declared.contains(where: { $0.utf8.elementsEqual(slots.index.utf8) }) else {
            throw CollectorPublicationWorkerError.invalidCapture
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

    private static func canonicalSlots(session: String) -> (events: String, workspace: String, index: String) {
        (
            session + "/" + eventsName,
            session + "/" + workspaceName,
            session + "/" + checkpointsDirectory + "/" + indexName
        )
    }

    static func sessionName(fromPrimary relative: String) -> String? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[1] == eventsName { return parts[0] }
        if parts.count == 3, parts[1] == checkpointsDirectory, parts[2] == indexName { return parts[0] }
        return nil
    }

    private enum Sniff { case found, absent, truncated, changed }

    private static func isSessionMember(_ parts: [String]) -> Bool {
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !parts[0].hasPrefix(".") else { return false }
        if parts.count == 1 { return true }
        if parts.count == 2 {
            return parts[1] == eventsName || parts[1] == workspaceName || parts[1] == checkpointsDirectory
        }
        return parts[1] == checkpointsDirectory
    }

    private static func sniffConversation(
        rootPath: String, relative: String, expected: ArchiveSourceGeneration, maximumByteCount: Int64
    ) throws -> Sniff {
        guard let limit = readLimit(size: expected.size, maximumByteCount: maximumByteCount) else { return .changed }
        let (bytes, reachedEnd): (Data, Bool)
        do { (bytes, reachedEnd) = try readFenced(rootPath: rootPath, relative: relative, expected: expected, limit: limit) }
        catch { return .changed }
        if bytesContainConversation(bytes) { return .found }
        if reachedEnd { return .absent }
        return .truncated
    }

    private static func sniffIndexRow(
        rootPath: String, relative: String, expected: ArchiveSourceGeneration, maximumByteCount: Int64
    ) throws -> Sniff {
        guard let limit = readLimit(size: expected.size, maximumByteCount: maximumByteCount) else { return .changed }
        let (bytes, reachedEnd): (Data, Bool)
        do { (bytes, reachedEnd) = try readFenced(rootPath: rootPath, relative: relative, expected: expected, limit: limit) }
        catch { return .changed }
        guard let text = String(data: bytes, encoding: .utf8) else { return reachedEnd ? .absent : .truncated }
        if text.split(separator: "\n", omittingEmptySubsequences: false).contains(where: isIndexRow) { return .found }
        if reachedEnd { return .absent }
        return .truncated
    }

    private static func readLimit(size: Int64, maximumByteCount: Int64) -> Int? {
        guard size >= 0, maximumByteCount > 0, maximumByteCount <= Int64(Int.max) else { return nil }
        if size > maximumByteCount { return Int(maximumByteCount) }
        return Int(size)
    }

    private static func bytesContainConversation(_ bytes: Data) -> Bool {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            let count = bytes.distance(from: start, to: newline)
            if count <= maximumConversationSniffLineBytes {
                let line = bytes[start..<newline]
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }),
                   let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   isConversationTurn(object) {
                    return true
                }
            }
            guard newline < bytes.endIndex else { break }
            start = bytes.index(after: newline)
        }
        return false
    }

    private static func isConversationTurn(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String,
              type == "user.message" || type == "assistant.message" else { return false }
        let data = object["data"] as? [String: Any]
        let content = (data?["content"] as? String) ?? ""
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isIndexRow(_ line: Substring) -> Bool {
        let columns = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return columns.count >= 4 && Int(columns[1]) != nil && !columns[2].isEmpty
    }

    private static func consider(
        name: String, relative: String, parent: Int32,
        present: inout [CollectorDependencySnapshot.PresentMember], absent: inout [String]
    ) throws {
        if let generation = try statRegularFile(parent: parent, name: name) {
            present.append(.init(relativePath: relative, generation: generation))
        } else {
            absent.append(relative)
        }
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

    private static func listRegularMarkdown(
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
            if name == "." || name == ".." || !name.lowercased().hasSuffix(".md") { continue }
            var info = stat()
            guard name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw CollectorPOSIXEnumerationError.io(.statEntry, errno)
            }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            result.append((name, try generation(from: info)))
        }
        return result
    }

    private static func regularFileExists(rootPath: String, relative: String) -> Bool {
        guard CollectorInventoryStore.isSafeRelativePath(relative) else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        guard let opened = try? CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        ) else { return false }
        var parent = opened.descriptor
        var owned = [parent]
        defer { for fd in owned.reversed() { CollectorPOSIXDirectoryAccess.close(fd) } }
        for part in parts.dropLast() {
            guard let next = try? CollectorPOSIXDirectoryAccess.openComponent(part, parent: parent) else { return false }
            owned.append(next)
            parent = next
        }
        let name = parts[parts.count - 1]
        var info = stat()
        let result = name.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        return result == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func readFenced(
        rootPath: String, relative: String, expected: ArchiveSourceGeneration, limit: Int
    ) throws -> (bytes: Data, reachedEnd: Bool) {
        try Task.checkCancellation()
        guard CollectorInventoryStore.isSafeRelativePath(relative), limit >= 0 else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = relative.split(separator: "/").map(String.init)
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        )
        var parent = opened.descriptor
        var owned = [parent]
        defer { for fd in owned.reversed() { CollectorPOSIXDirectoryAccess.close(fd) } }
        for part in parts.dropLast() {
            let next = try CollectorPOSIXDirectoryAccess.openComponent(part, parent: parent)
            owned.append(next)
            parent = next
        }
        let name = parts[parts.count - 1]
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var openedInfo = stat()
        var namedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              name.withCString({ fstatat(parent, $0, &namedInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
              openedInfo.st_dev == namedInfo.st_dev, openedInfo.st_ino == namedInfo.st_ino,
              openedInfo.st_mode & S_IFMT == S_IFREG,
              try generation(from: openedInfo) == expected else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        var bytes = Data()
        if limit > 0 {
            var buffer = [UInt8](repeating: 0, count: min(limit, 4096))
            while bytes.count < limit {
                try Task.checkCancellation()
                let want = min(buffer.count, limit - bytes.count)
                let readCount = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, want)
                }
                if readCount == 0 { break }
                if readCount < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytes.append(contentsOf: buffer.prefix(readCount))
            }
        }
        var afterInfo = stat()
        guard fstat(descriptor, &afterInfo) == 0, try generation(from: afterInfo) == expected else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return (bytes, bytes.count < limit || Int64(bytes.count) == expected.size)
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

    private static func stripYAMLQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" || first == "'"), first == last else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

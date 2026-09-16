import Darwin
import Foundation

enum CollectorGeminiSource {
    static let maximumRegistryBytes = 65_536
    static let maximumSessionLineBytes = 8 * 1024 * 1024

    private static let chatsName = "chats"
    private static let projectRootName = ".project_root"
    private static let sidecarSuffix = ".engram.json"

    static func isSelectedPrimary(rootPath: String, components: [String]) -> Bool {
        _ = rootPath
        guard components.count == 3, let project = components.first, let name = components.last,
              project != ".", project != "..",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components[1] == chatsName, !name.hasSuffix(sidecarSuffix) else { return false }
        return name.hasSuffix(".json") || name.hasSuffix(".jsonl")
    }

    static func owningPrimary(rootPath: String, dirtyRelative: String) -> String? {
        owningCandidates(rootPath: rootPath, dirtyRelative: dirtyRelative).first
    }

    static func owningCandidates(rootPath: String, dirtyRelative: String) -> [String] {
        let parts = dirtyRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let project = parts.first, !project.isEmpty, project != ".", project != ".." else { return [] }
        if isSelectedPrimary(rootPath: rootPath, components: parts) { return [dirtyRelative] }
        if parts.count == 2, parts[1] == projectRootName {
            return listTranscripts(rootPath: rootPath, project: project)
        }
        if parts.count == 3, parts[1] == chatsName, parts[2].hasSuffix(sidecarSuffix) {
            return listTranscripts(rootPath: rootPath, project: project)
        }
        return []
    }

    static func sessionOwning(_ relative: String) -> String? {
        owningPrimary(rootPath: "", dirtyRelative: relative)
    }

    static func observe(
        rootPath: String, primaryRelative: String, registryLocator: String?, maximumByteCount: Int64
    ) throws -> (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot) {
        try Task.checkCancellation()
        guard CollectorInventoryStore.isSafeRelativePath(primaryRelative),
              isSelectedPrimary(
                  rootPath: rootPath,
                  components: primaryRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
              ),
              let project = primaryRelative.split(separator: "/").first.map(String.init) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let root = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        )
        defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
        let projectFd = try CollectorPOSIXDirectoryAccess.openComponent(project, parent: root.descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(projectFd) }
        let chatsFd = try CollectorPOSIXDirectoryAccess.openComponent(chatsName, parent: projectFd)
        defer { CollectorPOSIXDirectoryAccess.close(chatsFd) }
        let transcriptName = String(primaryRelative.split(separator: "/").last!)
        guard let transcriptGeneration = try statRegularFile(parent: chatsFd, name: transcriptName) else {
            throw POSIXError(.ENOENT)
        }
        let sessionId = try sessionId(
            rootPath: rootPath, relative: primaryRelative, expected: transcriptGeneration,
            maximumByteCount: maximumByteCount
        )
        let sidecarRelative = project + "/" + chatsName + "/" + sessionId + sidecarSuffix
        let projectRootRelative = project + "/" + projectRootName
        var present: [CollectorDependencySnapshot.PresentMember] = [
            .init(relativePath: primaryRelative, generation: transcriptGeneration)
        ]
        var absent: [String] = []
        try consider(name: projectRootName, relative: projectRootRelative, parent: projectFd, present: &present, absent: &absent)
        try consider(name: sessionId + sidecarSuffix, relative: sidecarRelative, parent: chatsFd, present: &present, absent: &absent)
        present.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        absent.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let context = try projectContext(
            rootPath: rootPath, project: project, projectRootRelative: projectRootRelative,
            present: present, registryLocator: registryLocator
        )
        let snapshot = CollectorDependencySnapshot(
            entrypointRelativePath: primaryRelative, present: present, absentRelativePaths: absent,
            geminiProjectContext: context
        )
        try requireValidSnapshot(snapshot, entrypoint: primaryRelative)
        return (transcriptGeneration, snapshot)
    }

    static func registryGeneration(locator: String) throws -> ArchiveSourceGeneration? {
        try Task.checkCancellation()
        guard let normalized = ArchiveSourceDescriptor.fileSetAbsolutePath(locator),
              normalized.utf8.elementsEqual(locator.utf8) else {
            return nil
        }
        let parts = try CollectorPOSIXDirectoryAccess.components(locator)
        guard parts.count >= 1 else { return nil }
        let opened: (descriptor: Int32, info: stat)
        do {
            opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: Array(parts.dropLast()))
        } catch {
            return nil
        }
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        let name = parts[parts.count - 1]
        var info = stat()
        let result = name.withCString { fstatat(opened.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try generation(from: info)
    }

    static func membershipEquals(_ lhs: CollectorDependencySnapshot, _ rhs: CollectorDependencySnapshot) -> Bool {
        lhs.present == rhs.present && lhs.absentRelativePaths == rhs.absentRelativePaths
    }

    static func provenanceEquals(_ lhs: CollectorDependencySnapshot, _ rhs: CollectorDependencySnapshot) -> Bool {
        membershipEquals(lhs, rhs)
            && lhs.entrypointRelativePath.utf8.elementsEqual(rhs.entrypointRelativePath.utf8)
            && lhs.geminiProjectContext == rhs.geminiProjectContext
    }

    static func matchesReservedSnapshot(
        _ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest
    ) -> Bool {
        guard ArchiveSourceDescriptor.isGeminiFileSet(manifest),
              manifest.replayLayout.strategy == .fileSet,
              let files = manifest.replayLayout.files,
              let absent = manifest.replayLayout.absentRelativePaths,
              let entrypoint = manifest.replayLayout.entrypointRelativePath,
              entrypoint.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8),
              files.count == snapshot.present.count,
              absent.count == snapshot.absentRelativePaths.count,
              snapshot.geminiProjectContext == manifest.replayLayout.geminiProjectContext else {
            return false
        }
        if snapshot.geminiProjectContext == nil {
            guard manifest.schemaVersion == 2 else { return false }
        } else {
            guard manifest.schemaVersion == 3 else { return false }
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
        guard snapshot.entrypointRelativePath.utf8.elementsEqual(entrypoint.utf8),
              isSelectedPrimary(rootPath: "", components: parts),
              let project = parts.first else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let projectRoot = project + "/" + projectRootName
        let declared = snapshot.present.map(\.relativePath) + snapshot.absentRelativePaths
        let extras = declared.filter {
            !$0.utf8.elementsEqual(entrypoint.utf8) && !$0.utf8.elementsEqual(projectRoot.utf8)
        }
        guard declared.count == 3, declared.count == Set(declared).count,
              snapshot.present.contains(where: { $0.relativePath.utf8.elementsEqual(entrypoint.utf8) }),
              declared.contains(where: { $0.utf8.elementsEqual(projectRoot.utf8) }),
              extras.count == 1 else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let sidecar = extras[0].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard sidecar.count == 3, sidecar[0].utf8.elementsEqual(project.utf8),
              sidecar[1] == chatsName, sidecar[2].hasSuffix(sidecarSuffix),
              sidecar[2].utf8.count > sidecarSuffix.utf8.count else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        if let context = snapshot.geminiProjectContext {
            guard context.projectName.utf8.elementsEqual(project.utf8) else {
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

    static func sessionId(from bytes: Data, jsonl: Bool) -> String? {
        if jsonl { return jsonlSessionId(bytes) }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return sessionId(updating: nil, object: object)
    }

    static func projectRootSuppliesCWD(_ bytes: Data) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func recognizedConversation(_ bytes: Data, jsonl: Bool, maxLineBytes: Int, maxRecords: Int) -> Bool {
        if jsonl {
            return jsonlRecognized(bytes, maxLineBytes: maxLineBytes, maxRecords: maxRecords)
        }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let messages = object["messages"] as? [Any] else { return false }
        var count = 0
        for item in messages {
            guard let message = item as? [String: Any] else { return false }
            count += 1
            guard count <= maxRecords else { return false }
            if isRecognizedMessage(message) { return true }
        }
        return false
    }

    private static func projectContext(
        rootPath: String, project: String, projectRootRelative: String,
        present: [CollectorDependencySnapshot.PresentMember], registryLocator: String?
    ) throws -> ArchiveGeminiProjectContext? {
        if let member = present.first(where: { $0.relativePath.utf8.elementsEqual(projectRootRelative.utf8) }),
           member.generation.size >= 0, member.generation.size <= Int64(Int.max),
           let bytes = try? readFenced(
               rootPath: rootPath, relative: projectRootRelative, expected: member.generation,
               limit: Int(member.generation.size)
           ),
           projectRootSuppliesCWD(bytes) {
            return nil
        }
        guard let registryLocator else { return nil }
        return try observeRegistry(locator: registryLocator, projectName: project)
    }

    private static func observeRegistry(
        locator: String, projectName: String
    ) throws -> ArchiveGeminiProjectContext {
        try Task.checkCancellation()
        guard let normalized = ArchiveSourceDescriptor.fileSetAbsolutePath(locator),
              normalized.utf8.elementsEqual(locator.utf8) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = try CollectorPOSIXDirectoryAccess.components(locator)
        guard parts.count >= 1 else { throw CollectorPublicationWorkerError.invalidCapture }
        let parentParts = Array(parts.dropLast())
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: parentParts)
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        let name = parts[parts.count - 1]
        let descriptor = name.withCString { openat(opened.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
        guard fstat(descriptor, &after) == 0, try Self.generation(from: after) == generation,
              bytes.count == Int(generation.size) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        guard let cwd = uniqueRegistryCWD(bytes: bytes, projectName: projectName) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return try ArchiveGeminiProjectContext(
            projectName: projectName, cwd: cwd, registryLocator: locator,
            registryGeneration: generation, registrySHA256: ArchiveV2Hash.sha256(bytes)
        )
    }

    private static func uniqueRegistryCWD(bytes: Data, projectName: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        let raw = (object["projects"] as? [String: Any]) ?? object
        let matches = raw.compactMap { cwd, value -> String? in
            guard let name = value as? String, name.utf8.elementsEqual(projectName.utf8) else { return nil }
            return cwd
        }
        guard matches.count == 1, let cwd = matches.first, cwd.hasPrefix("/"), !cwd.utf8.contains(0) else {
            return nil
        }
        return cwd
    }

    private static func sessionId(
        rootPath: String, relative: String, expected: ArchiveSourceGeneration, maximumByteCount: Int64
    ) throws -> String {
        guard expected.size > 0, expected.size <= maximumByteCount, maximumByteCount <= Int64(Int.max) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let bytes = try readFenced(rootPath: rootPath, relative: relative, expected: expected, limit: Int(expected.size))
        guard bytes.count == Int(expected.size),
              let sessionId = sessionId(from: bytes, jsonl: relative.hasSuffix(".jsonl")),
              !sessionId.isEmpty, sessionId != ".", sessionId != "..",
              !sessionId.contains("/"), !sessionId.utf8.contains(0),
              CollectorInventoryStore.isSafeRelativePath(sessionId + sidecarSuffix) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return sessionId
    }

    private static func sessionId(updating current: String?, object: [String: Any]) -> String? {
        if let update = object["$set"] as? [String: Any] {
            return applySessionId(current, from: update)
        }
        if object["$rewindTo"] is String { return current }
        if object["type"] is String { return current }
        return applySessionId(current, from: object)
    }

    private static func applySessionId(_ current: String?, from object: [String: Any]) -> String? {
        guard object.keys.contains("sessionId") else { return current }
        return string(object["sessionId"])
    }

    private static func jsonlSessionId(_ bytes: Data) -> String? {
        var sessionId: String?
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            let count = bytes.distance(from: start, to: newline)
            if count > maximumSessionLineBytes { return nil }
            let line = bytes[start..<newline]
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    return nil
                }
                sessionId = Self.sessionId(updating: sessionId, object: object)
            }
            guard newline < bytes.endIndex else { break }
            start = bytes.index(after: newline)
        }
        return sessionId
    }

    private static func jsonlRecognized(_ bytes: Data, maxLineBytes: Int, maxRecords: Int) -> Bool {
        var start = bytes.startIndex
        var records = 0
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            let count = bytes.distance(from: start, to: newline)
            if count <= maxLineBytes {
                let line = bytes[start..<newline]
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    records += 1
                    if records > maxRecords { return false }
                    if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        // Match native replay precedence: updates and rewinds
                        // take priority over any top-level message fields.
                        let messages: [Any]?
                        if let update = object["$set"] as? [String: Any] {
                            messages = update["messages"] as? [Any]
                        } else if object["$rewindTo"] is String {
                            messages = nil
                        } else if object["type"] is String {
                            if isRecognizedMessage(object) { return true }
                            messages = nil
                        } else {
                            messages = object["messages"] as? [Any]
                        }
                        for item in messages ?? [] {
                            records += 1
                            guard records <= maxRecords else { return false }
                            if let message = item as? [String: Any], isRecognizedMessage(message) {
                                return true
                            }
                        }
                    }
                }
            }
            guard newline < bytes.endIndex else { break }
            start = bytes.index(after: newline)
        }
        return false
    }

    private static func isRecognizedMessage(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String,
              type == "user" || type == "gemini" || type == "model" else { return false }
        if let content = object["content"] as? String {
            return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let parts = object["content"] as? [Any] {
            return parts.contains { item in
                if let text = item as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let object = item as? [String: Any], let text = object["text"] as? String {
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            }
        }
        return false
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func listTranscripts(rootPath: String, project: String) -> [String] {
        guard let opened = try? CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        ) else { return [] }
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        guard let projectFd = try? CollectorPOSIXDirectoryAccess.openComponent(project, parent: opened.descriptor) else {
            return []
        }
        defer { CollectorPOSIXDirectoryAccess.close(projectFd) }
        guard let chats = try? CollectorPOSIXDirectoryAccess.openComponent(chatsName, parent: projectFd) else {
            return []
        }
        defer { CollectorPOSIXDirectoryAccess.close(chats) }
        return ((try? listRegularNames(directory: chats)) ?? []).compactMap { name in
            let relative = project + "/" + chatsName + "/" + name
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return isSelectedPrimary(rootPath: rootPath, components: parts) ? relative : nil
        }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func listRegularNames(directory fd: Int32) throws -> [String] {
        let duplicated = dup(fd)
        guard duplicated >= 0 else { throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno) }
        guard let stream = fdopendir(duplicated) else {
            _ = Darwin.close(duplicated)
            throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno)
        }
        defer { closedir(stream) }
        var names: [String] = []
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
            var info = stat()
            guard name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw CollectorPOSIXEnumerationError.io(.statEntry, errno)
            }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            names.append(name)
        }
        return names
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

    private static func readFenced(
        rootPath: String, relative: String, expected: ArchiveSourceGeneration, limit: Int
    ) throws -> Data {
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
        return bytes
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

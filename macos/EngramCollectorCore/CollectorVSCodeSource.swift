import Darwin
import Foundation

/// POSIX metadata selection for a VS Code chat primary plus frozen workspace
/// sidecar. Not a parser and not Runtime/HQ/inventory integration.
enum CollectorVSCodeSource {
    static let chatsName = "chatSessions"
    static let workspaceName = "workspace.json"

    static func isSelectedPrimary(rootPath: String, components: [String]) -> Bool {
        _ = rootPath
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components[1] == chatsName,
              components[2].hasSuffix(".jsonl"),
              components[2].utf8.count > 6 else { return false }
        return CollectorInventoryStore.isSafeRelativePath(components.joined(separator: "/"))
    }

    static func observe(
        rootPath: String, primaryRelative: String, maximumByteCount: Int64,
        testHooks: CollectorPOSIXRootEnumeratorTestHooks = .init()
    ) throws -> (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot) {
        try Task.checkCancellation()
        guard maximumByteCount > 0,
              CollectorInventoryStore.isSafeRelativePath(primaryRelative),
              isSelectedPrimary(
                  rootPath: rootPath,
                  components: primaryRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
              ) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = primaryRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let workspaceRelative = parts[0] + "/" + workspaceName
        let rootComponents = try CollectorPOSIXDirectoryAccess.components(rootPath)
        let root = try CollectorPOSIXDirectoryAccess.openAbsolute(components: rootComponents, testHooks: testHooks)
        defer { CollectorPOSIXDirectoryAccess.close(root.descriptor, testHooks: testHooks) }
        let rootIdentity = try CollectorPOSIXDirectoryAccess.identity(root.info)
        let workspaceFd = try openFencedDirectory(parts[0], parent: root.descriptor, testHooks: testHooks)
        defer { CollectorPOSIXDirectoryAccess.close(workspaceFd, testHooks: testHooks) }
        let workspaceIdentity = try CollectorPOSIXDirectoryAccess.identity(
            CollectorPOSIXDirectoryAccess.directoryStat(workspaceFd)
        )
        let chatsFd = try openFencedDirectory(chatsName, parent: workspaceFd, testHooks: testHooks)
        defer { CollectorPOSIXDirectoryAccess.close(chatsFd, testHooks: testHooks) }
        let chatsIdentity = try CollectorPOSIXDirectoryAccess.identity(
            CollectorPOSIXDirectoryAccess.directoryStat(chatsFd)
        )
        guard let primaryGeneration = try statRegularFile(parent: chatsFd, name: parts[2]) else {
            throw POSIXError(.ENOENT)
        }
        guard primaryGeneration.size <= maximumByteCount else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        var remaining = maximumByteCount - primaryGeneration.size
        var present = [CollectorDependencySnapshot.PresentMember(
            relativePath: primaryRelative, generation: primaryGeneration
        )]
        var absent: [String] = []
        let workspaceBytes: Data?
        if let workspaceGeneration = try statRegularFile(parent: workspaceFd, name: workspaceName) {
            guard workspaceGeneration.size <= ArchiveVSCodeWorkspaceContext.maximumContextBytes,
                  workspaceGeneration.size <= remaining else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            remaining -= workspaceGeneration.size
            workspaceBytes = try readFencedFile(
                parent: workspaceFd, name: workspaceName, expected: workspaceGeneration
            )
            present.append(.init(relativePath: workspaceRelative, generation: workspaceGeneration))
        } else {
            workspaceBytes = nil
            absent.append(workspaceRelative)
        }
        let context = try workspaceContext(
            workspaceBytes, remaining: &remaining, testHooks: testHooks
        )
        try recheck(
            rootPath: rootPath, rootComponents: rootComponents, rootIdentity: rootIdentity,
            workspaceName: parts[0], workspaceIdentity: workspaceIdentity,
            chatsIdentity: chatsIdentity, primaryName: parts[2], primaryGeneration: primaryGeneration,
            workspaceRelative: workspaceRelative, workspaceBytes: workspaceBytes,
            present: present, context: context, testHooks: testHooks
        )
        present.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        absent.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let snapshot = CollectorDependencySnapshot(
            entrypointRelativePath: primaryRelative, present: present, absentRelativePaths: absent,
            vscodeWorkspaceContext: context
        )
        try requireValidSnapshot(snapshot, entrypoint: primaryRelative)
        return (primaryGeneration, snapshot)
    }

    /// Stat-only reconciliation of captured inputs. No journal, workspace or
    /// external configuration payload is read on the unchanged path.
    static func capturedDependenciesChanged(rootPath: String, manifest: ArchiveSourceManifest) throws -> Bool {
        guard ArchiveSourceDescriptor.isVSCodeFileSet(manifest),
              let entrypoint = manifest.replayLayout.entrypointRelativePath,
              let context = manifest.replayLayout.vscodeWorkspaceContext,
              let files = manifest.replayLayout.files else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let parts = entrypoint.split(separator: "/").map(String.init)
        do {
            try Task.checkCancellation()
            let components = try CollectorPOSIXDirectoryAccess.components(rootPath)
            let root = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
            defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
            let workspace = try openFencedDirectory(parts[0], parent: root.descriptor, testHooks: .init())
            defer { CollectorPOSIXDirectoryAccess.close(workspace) }
            let chats = try openFencedDirectory(chatsName, parent: workspace, testHooks: .init())
            defer { CollectorPOSIXDirectoryAccess.close(chats) }
            guard try statRegularFile(parent: chats, name: parts[2]) == manifest.generation else { return true }
            let workspaceGeneration = files.first { $0.relativePath.utf8.elementsEqual((parts[0] + "/" + workspaceName).utf8) }?.generation
            guard try statRegularFile(parent: workspace, name: workspaceName) == workspaceGeneration else { return true }
            try recheckExternal(context, testHooks: .init())
            let namedRoot = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
            defer { CollectorPOSIXDirectoryAccess.close(namedRoot.descriptor) }
            guard try CollectorPOSIXDirectoryAccess.identity(namedRoot.info)
                == CollectorPOSIXDirectoryAccess.identity(root.info) else { return true }
            let namedWorkspace = try openFencedDirectory(parts[0], parent: namedRoot.descriptor, testHooks: .init())
            defer { CollectorPOSIXDirectoryAccess.close(namedWorkspace) }
            guard try CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(namedWorkspace))
                == CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(workspace)) else { return true }
            let namedChats = try openFencedDirectory(chatsName, parent: namedWorkspace, testHooks: .init())
            defer { CollectorPOSIXDirectoryAccess.close(namedChats) }
            guard try CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(namedChats))
                == CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(chats)) else { return true }
            return false
        } catch is CancellationError { throw CancellationError() }
        catch { return true }
    }

    static func requireValidSnapshot(_ snapshot: CollectorDependencySnapshot, entrypoint: String) throws {
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard snapshot.geminiProjectContext == nil, snapshot.kimiProjectContext == nil,
              let context = snapshot.vscodeWorkspaceContext,
              snapshot.entrypointRelativePath.utf8.elementsEqual(entrypoint.utf8),
              isSelectedPrimary(rootPath: "", components: parts) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let workspacePath = parts[0] + "/" + workspaceName
        let declared = (snapshot.present.map(\.relativePath) + snapshot.absentRelativePaths).map { Data($0.utf8) }
        guard Set(declared) == Set([Data(entrypoint.utf8), Data(workspacePath.utf8)]),
              declared.count == 2,
              snapshot.present.contains(where: { $0.relativePath.utf8.elementsEqual(entrypoint.utf8) }),
              context.configurationLocator == nil
                || snapshot.present.contains(where: { $0.relativePath.utf8.elementsEqual(workspacePath.utf8) }),
              snapshot.present.filter({ $0.relativePath.utf8.elementsEqual(workspacePath.utf8) })
                .allSatisfy({ $0.generation.size <= ArchiveVSCodeWorkspaceContext.maximumContextBytes })
        else {
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

    static func matchesReservedSnapshot(
        _ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest
    ) -> Bool {
        guard (try? requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)) != nil,
              ArchiveSourceDescriptor.isVSCodeFileSet(manifest),
              manifest.schemaVersion == 7,
              let files = manifest.replayLayout.files,
              let absent = manifest.replayLayout.absentRelativePaths,
              let entrypoint = manifest.replayLayout.entrypointRelativePath,
              entrypoint.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8),
              files.count == snapshot.present.count,
              absent.count == snapshot.absentRelativePaths.count,
              snapshot.vscodeWorkspaceContext == manifest.replayLayout.vscodeWorkspaceContext else {
            return false
        }
        return zip(files, snapshot.present).allSatisfy {
            $0.relativePath.utf8.elementsEqual($1.relativePath.utf8) && $0.generation == $1.generation
        } && zip(absent, snapshot.absentRelativePaths).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    private static func workspaceContext(
        _ workspaceBytes: Data?, remaining: inout Int64,
        testHooks: CollectorPOSIXRootEnumeratorTestHooks
    ) throws -> ArchiveVSCodeWorkspaceContext {
        let context: ArchiveVSCodeWorkspaceContext
        if let workspaceBytes {
            guard let object = try? JSONSerialization.jsonObject(with: workspaceBytes) as? [String: Any] else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            if object["folder"] as? String != nil {
                context = try ArchiveVSCodeWorkspaceContext()
            } else if let uri = object["configuration"] as? String {
                let locator = try configurationLocator(uri)
                switch try externalConfiguration(locator, remaining: &remaining, testHooks: testHooks) {
                case .present(let data, let generation, let digest):
                    context = try ArchiveVSCodeWorkspaceContext(
                        configurationLocator: locator, configurationGeneration: generation,
                        configurationData: data, configurationSHA256: digest
                    )
                case .absent:
                    context = try ArchiveVSCodeWorkspaceContext(configurationLocator: locator)
                }
            } else {
                context = try ArchiveVSCodeWorkspaceContext()
            }
        } else {
            context = try ArchiveVSCodeWorkspaceContext()
        }
        try context.validateWorkspaceData(workspaceBytes)
        return context
    }

    private static func recheck(
        rootPath: String, rootComponents: [String], rootIdentity: CollectorPOSIXDirectoryIdentity,
        workspaceName: String, workspaceIdentity: CollectorPOSIXDirectoryIdentity,
        chatsIdentity: CollectorPOSIXDirectoryIdentity, primaryName: String,
        primaryGeneration: ArchiveSourceGeneration, workspaceRelative: String, workspaceBytes: Data?,
        present: [CollectorDependencySnapshot.PresentMember], context: ArchiveVSCodeWorkspaceContext,
        testHooks: CollectorPOSIXRootEnumeratorTestHooks
    ) throws {
        try Task.checkCancellation()
        let namedRoot = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: rootComponents, testHooks: testHooks
        )
        defer { CollectorPOSIXDirectoryAccess.close(namedRoot.descriptor, testHooks: testHooks) }
        guard try CollectorPOSIXDirectoryAccess.identity(namedRoot.info) == rootIdentity else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let namedWorkspace = try openFencedDirectory(
            workspaceName, parent: namedRoot.descriptor, testHooks: testHooks
        )
        defer { CollectorPOSIXDirectoryAccess.close(namedWorkspace, testHooks: testHooks) }
        guard try CollectorPOSIXDirectoryAccess.identity(
            CollectorPOSIXDirectoryAccess.directoryStat(namedWorkspace)
        ) == workspaceIdentity else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let namedChats = try openFencedDirectory(chatsName, parent: namedWorkspace, testHooks: testHooks)
        defer { CollectorPOSIXDirectoryAccess.close(namedChats, testHooks: testHooks) }
        guard try CollectorPOSIXDirectoryAccess.identity(
            CollectorPOSIXDirectoryAccess.directoryStat(namedChats)
        ) == chatsIdentity else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        guard try statRegularFile(parent: namedChats, name: primaryName) == primaryGeneration else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        if let expected = present.first(where: { $0.relativePath.utf8.elementsEqual(workspaceRelative.utf8) }) {
            guard try statRegularFile(parent: namedWorkspace, name: Self.workspaceName) == expected.generation else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        } else {
            guard try statRegularFile(parent: namedWorkspace, name: Self.workspaceName) == nil else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
        try context.validateWorkspaceData(workspaceBytes)
        try recheckExternal(context, testHooks: testHooks)
    }

    private static func recheckExternal(
        _ context: ArchiveVSCodeWorkspaceContext, testHooks: CollectorPOSIXRootEnumeratorTestHooks
    ) throws {
        guard let locator = context.configurationLocator else { return }
        switch try openExternalParent(locator, testHooks: testHooks) {
        case .missing:
            guard context.configurationGeneration == nil, context.configurationData == nil,
                  context.configurationSHA256 == nil else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        case .complete(let parent, let leaf, let owned):
            defer { owned.reversed().forEach { CollectorPOSIXDirectoryAccess.close($0, testHooks: testHooks) } }
            if let generation = context.configurationGeneration {
                guard context.configurationData != nil, context.configurationSHA256 != nil,
                      try statRegularFile(parent: parent, name: leaf) == generation else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
            } else {
                guard context.configurationData == nil, context.configurationSHA256 == nil,
                      try proveNamedAbsence(parent: parent, name: leaf) else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
            }
        }
    }

    private enum ExternalObservation {
        case present(Data, ArchiveSourceGeneration, String)
        case absent
    }

    private enum ExternalParent {
        case complete(parent: Int32, leaf: String, owned: [Int32])
        case missing
    }

    private static func externalConfiguration(
        _ locator: String, remaining: inout Int64, testHooks: CollectorPOSIXRootEnumeratorTestHooks
    ) throws -> ExternalObservation {
        switch try openExternalParent(locator, testHooks: testHooks) {
        case .missing:
            return .absent
        case .complete(let parent, let leaf, let owned):
            defer { owned.reversed().forEach { CollectorPOSIXDirectoryAccess.close($0, testHooks: testHooks) } }
            guard let generation = try statRegularFile(parent: parent, name: leaf) else {
                guard try proveNamedAbsence(parent: parent, name: leaf) else {
                    throw CollectorPublicationWorkerError.invalidCapture
                }
                return .absent
            }
            guard generation.size <= ArchiveVSCodeWorkspaceContext.maximumContextBytes,
                  generation.size <= remaining else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            remaining -= generation.size
            let data = try readFencedFile(parent: parent, name: leaf, expected: generation)
            return .present(data, generation, ArchiveV2Hash.sha256(data))
        }
    }

    private static func configurationLocator(_ uri: String) throws -> String {
        guard uri.hasPrefix("file://") else { throw CollectorPublicationWorkerError.invalidCapture }
        var encoded = String(uri.dropFirst(7))
        if encoded.hasPrefix("localhost/") { encoded = String(encoded.dropFirst(9)) }
        guard let path = encoded.removingPercentEncoding, path.hasPrefix("/"),
              path.utf8.count <= 4096,
              ArchiveReplayLayout.isNormalizedRelativePath(String(path.dropFirst())) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return path
    }

    /// Full parent chain or explicit missing ancestor. Never returns a partial
    /// ancestor as a leaf parent — a same-named decoy there is not this locator.
    private static func openExternalParent(
        _ locator: String, testHooks: CollectorPOSIXRootEnumeratorTestHooks
    ) throws -> ExternalParent {
        try Task.checkCancellation()
        let parts = try CollectorPOSIXDirectoryAccess.components(locator)
        guard let leaf = parts.last else { throw CollectorPublicationWorkerError.invalidCapture }
        var parent = try CollectorPOSIXDirectoryAccess.openComponent("/", parent: AT_FDCWD, testHooks: testHooks)
        var owned = [parent]
        do {
            for name in parts.dropLast() {
                try Task.checkCancellation()
                if try namedEntryMissing(parent: parent, name: name) {
                    owned.reversed().forEach { CollectorPOSIXDirectoryAccess.close($0, testHooks: testHooks) }
                    return .missing
                }
                let child = try openFencedDirectory(name, parent: parent, testHooks: testHooks)
                owned.append(child)
                parent = child
            }
            return .complete(parent: parent, leaf: leaf, owned: owned)
        } catch {
            owned.reversed().forEach { CollectorPOSIXDirectoryAccess.close($0, testHooks: testHooks) }
            throw error
        }
    }

    private static func namedEntryMissing(parent: Int32, name: String) throws -> Bool {
        let before = try CollectorPOSIXDirectoryAccess.directoryStat(parent)
        var named = stat()
        let result = name.withCString { fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { return false }
        guard errno == ENOENT else { throw CollectorPublicationWorkerError.invalidCapture }
        var again = stat()
        let retry = name.withCString { fstatat(parent, $0, &again, AT_SYMLINK_NOFOLLOW) }
        guard retry != 0, errno == ENOENT else { throw CollectorPublicationWorkerError.invalidCapture }
        let after = try CollectorPOSIXDirectoryAccess.directoryStat(parent)
        guard try CollectorPOSIXDirectoryAccess.identity(before) == CollectorPOSIXDirectoryAccess.identity(after) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        return true
    }

    private static func proveNamedAbsence(parent: Int32, name: String) throws -> Bool {
        try namedEntryMissing(parent: parent, name: name)
    }

    private static func openFencedDirectory(
        _ name: String, parent: Int32, testHooks: CollectorPOSIXRootEnumeratorTestHooks
    ) throws -> Int32 {
        var named = stat()
        guard name.withCString({ fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              named.st_mode & S_IFMT == S_IFDIR else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let descriptor = try CollectorPOSIXDirectoryAccess.openComponent(name, parent: parent, testHooks: testHooks)
        do {
            let opened = try CollectorPOSIXDirectoryAccess.directoryStat(descriptor)
            guard opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            return descriptor
        } catch {
            CollectorPOSIXDirectoryAccess.close(descriptor, testHooks: testHooks)
            throw error
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

    private static func readFencedFile(
        parent: Int32, name: String, expected: ArchiveSourceGeneration
    ) throws -> Data {
        try Task.checkCancellation()
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
        let limit = Int(expected.size)
        var bytes = Data()
        if limit > 0 {
            var buffer = [UInt8](repeating: 0, count: min(limit, 4096))
            while bytes.count < limit {
                try Task.checkCancellation()
                let want = min(buffer.count, limit - bytes.count)
                let readCount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, want) }
                if readCount == 0 { break }
                if readCount < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytes.append(contentsOf: buffer.prefix(readCount))
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, try generation(from: after) == expected,
              bytes.count == limit else {
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

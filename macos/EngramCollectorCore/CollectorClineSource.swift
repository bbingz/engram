import Darwin
import Foundation

/// POSIX metadata selection for a Cline task primary. Not a parser and not a
/// Runtime/HQ integration. `ui_messages.json` wins; `claude_messages.json` is
/// eligible only after an ENOENT proof that UI is absent. An unsafe/symlink UI
/// is never treated as absence.
enum CollectorClineSource {
    static let uiName = "ui_messages.json"
    static let legacyName = "claude_messages.json"

    static func isSelectedPrimary(rootPath: String, components: [String]) -> Bool {
        _ = rootPath
        guard components.count == 2,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            return false
        }
        return components[1] == uiName || components[1] == legacyName
    }

    static func owningPrimary(rootPath: String, dirtyRelative: String) throws -> String? {
        try Task.checkCancellation()
        guard CollectorInventoryStore.isSafeRelativePath(dirtyRelative) else { return nil }
        let parts = dirtyRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard isSelectedPrimary(rootPath: rootPath, components: parts) else { return nil }
        return try selectedPrimary(rootPath: rootPath, task: parts[0]).relative
    }

    static func observe(
        rootPath: String, primaryRelative: String
    ) throws -> (generation: ArchiveSourceGeneration, snapshot: CollectorDependencySnapshot) {
        try Task.checkCancellation()
        guard CollectorInventoryStore.isSafeRelativePath(primaryRelative),
              isSelectedPrimary(
                  rootPath: rootPath,
                  components: primaryRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
              ) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let selected = try selectedPrimary(rootPath: rootPath, task: taskName(primaryRelative))
        guard primaryRelative.utf8.elementsEqual(selected.relative.utf8) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let present = [CollectorDependencySnapshot.PresentMember(
            relativePath: selected.relative, generation: selected.generation
        )]
        let absent = selected.uiAbsentProof.map { [$0] } ?? []
        let snapshot = CollectorDependencySnapshot(
            entrypointRelativePath: primaryRelative, present: present, absentRelativePaths: absent
        )
        try requireValidSnapshot(snapshot, entrypoint: primaryRelative)
        return (selected.generation, snapshot)
    }

    static func requireValidSnapshot(_ snapshot: CollectorDependencySnapshot, entrypoint: String) throws {
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard snapshot.geminiProjectContext == nil, snapshot.kimiProjectContext == nil,
              snapshot.entrypointRelativePath.utf8.elementsEqual(entrypoint.utf8),
              isSelectedPrimary(rootPath: "", components: parts),
              snapshot.present.count == 1,
              snapshot.present[0].relativePath.utf8.elementsEqual(entrypoint.utf8) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        if parts[1] == uiName {
            guard snapshot.absentRelativePaths.isEmpty else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        } else {
            let proof = parts[0] + "/" + uiName
            guard snapshot.absentRelativePaths.count == 1, snapshot.absentRelativePaths[0].utf8.elementsEqual(proof.utf8) else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
        }
    }

    static func matchesReservedSnapshot(
        _ snapshot: CollectorDependencySnapshot, manifest: ArchiveSourceManifest
    ) -> Bool {
        guard (try? requireValidSnapshot(snapshot, entrypoint: snapshot.entrypointRelativePath)) != nil,
              ArchiveSourceDescriptor.isClineFileSet(manifest),
              let files = manifest.replayLayout.files,
              let absent = manifest.replayLayout.absentRelativePaths,
              manifest.replayLayout.entrypointRelativePath?.utf8.elementsEqual(snapshot.entrypointRelativePath.utf8) == true,
              files.count == snapshot.present.count, absent.count == snapshot.absentRelativePaths.count else { return false }
        return zip(files, snapshot.present).allSatisfy {
            $0.relativePath.utf8.elementsEqual($1.relativePath.utf8) && $0.generation == $1.generation
        } && zip(absent, snapshot.absentRelativePaths).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    private static func selectedPrimary(
        rootPath: String, task: String
    ) throws -> (relative: String, generation: ArchiveSourceGeneration, uiAbsentProof: String?) {
        try Task.checkCancellation()
        guard CollectorInventoryStore.isSafeRelativePath(task + "/" + uiName) else {
            throw CollectorPublicationWorkerError.invalidCapture
        }
        let root = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(rootPath)
        )
        defer { CollectorPOSIXDirectoryAccess.close(root.descriptor) }
        let taskFd = try CollectorPOSIXDirectoryAccess.openComponent(task, parent: root.descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(taskFd) }
        if let ui = try statRegularFile(parent: taskFd, name: uiName) {
            return (task + "/" + uiName, ui, nil)
        }
        guard let legacy = try statRegularFile(parent: taskFd, name: legacyName) else {
            throw POSIXError(.ENOENT)
        }
        return (task + "/" + legacyName, legacy, task + "/" + uiName)
    }

    private static func taskName(_ relative: String) -> String {
        String(relative.split(separator: "/", omittingEmptySubsequences: false)[0])
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

import Darwin
import Foundation

// Supplied by the owner. This slice never discovers or persists a root binding.
struct CollectorPOSIXDirectoryIdentity: Equatable {
    let device: Int64
    let inode: Int64
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

struct CollectorPOSIXRootBinding {
    let configuration: CollectorRootConfiguration
    let expectedIdentity: CollectorPOSIXDirectoryIdentity
}

enum CollectorPOSIXOperation: String, Equatable {
    case openComponent
    case statDirectory
    case openDirectoryStream
    case readDirectory
    case statEntry
}

enum CollectorPOSIXEnumerationError: Error, Equatable {
    case invalidBinding
    case configurationMismatch
    case unsafePath
    case depthLimit
    case rootIdentityChanged
    case directoryIdentityChanged
    case directoryContentsChanged
    case invalidEntryName
    case io(CollectorPOSIXOperation, Int32)
    case notImplemented
}

// Narrow fixture-only observation/fault boundaries, not a filesystem abstraction.
// Read faults model a null readdir result with errno; stream faults model a
// failed fdopendir before ownership of its input fd transfers to DIR.
struct CollectorPOSIXRootEnumeratorTestHooks {
    var beforeOpenComponent: ((String) throws -> Void)?
    var afterCursorOpened: ((String, Int32) throws -> Void)?
    var beforeReadEntry: (() throws -> Void)?
    var afterReadEntry: ((String?) throws -> Void)?
    var readDirectoryFailure: (() -> Int32?)?
    var directoryStreamFailure: (() -> Int32?)?
    var didOpenDescriptor: ((Int32) -> Void)?
    var didCloseDescriptor: ((Int32, Bool) -> Void)?
}

// Shared native primitives for source binding and the inventory owner's explicit
// storage paths. This does not enumerate, canonicalize, create, or repair paths.
enum CollectorPOSIXDirectoryAccess {
    static func components(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), path.utf8.count <= CollectorPOSIXRootEnumerator.maximumPathBytes,
              CollectorInventoryStore.isSafeRelativePath(String(path.dropFirst())) else {
            throw CollectorPOSIXEnumerationError.invalidBinding
        }
        let components = path.dropFirst().split(separator: "/").map(String.init)
        guard components.count <= CollectorPOSIXRootEnumerator.maximumAbsoluteComponents else {
            throw CollectorPOSIXEnumerationError.invalidBinding
        }
        return components
    }

    static func openAbsolute(
        components: [String], testHooks: CollectorPOSIXRootEnumeratorTestHooks = .init()
    ) throws -> (descriptor: Int32, info: stat) {
        guard components.count <= CollectorPOSIXRootEnumerator.maximumAbsoluteComponents,
              try self.components("/" + components.joined(separator: "/")) == components else {
            throw CollectorPOSIXEnumerationError.invalidBinding
        }
        var descriptor = try openComponent("/", parent: AT_FDCWD, testHooks: testHooks)
        defer { if descriptor >= 0 { close(descriptor, testHooks: testHooks) } }
        for component in components {
            let next = try openComponent(component, parent: descriptor, testHooks: testHooks)
            close(descriptor, testHooks: testHooks)
            descriptor = next
        }
        let info = try directoryStat(descriptor)
        let result = descriptor
        descriptor = -1
        return (result, info)
    }

    static func openComponent(
        _ component: String, parent: Int32, testHooks: CollectorPOSIXRootEnumeratorTestHooks = .init()
    ) throws -> Int32 {
        try Task.checkCancellation()
        try testHooks.beforeOpenComponent?(component)
        let descriptor = component.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CollectorPOSIXEnumerationError.io(.openComponent, errno) }
        testHooks.didOpenDescriptor?(descriptor)
        do {
            try Task.checkCancellation()
            return descriptor
        } catch {
            close(descriptor, testHooks: testHooks)
            throw error
        }
    }

    static func close(_ descriptor: Int32, testHooks: CollectorPOSIXRootEnumeratorTestHooks = .init()) {
        _ = Darwin.close(descriptor)
        testHooks.didCloseDescriptor?(descriptor, false)
    }

    static func directoryStat(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CollectorPOSIXEnumerationError.io(.statDirectory, errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CollectorPOSIXEnumerationError.unsafePath }
        return info
    }

    static func identity(_ info: stat) throws -> CollectorPOSIXDirectoryIdentity {
        guard let inode = Int64(exactly: info.st_ino) else { throw CollectorPOSIXEnumerationError.io(.statDirectory, EOVERFLOW) }
        return .init(
            device: Int64(info.st_dev), inode: inode, generation: info.st_gen,
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }
}

// A logical cursor open is not one openat syscall. Safety validation may walk
// bounded root/relative component chains before and after a directory read.
// libc read-ahead and blocking kernel calls are not hard byte/time budgets.
final class CollectorPOSIXRootEnumerator: CollectorRootEnumerator {
    static let maximumAbsoluteComponents = 32
    static let maximumRelativeDepth = 32
    static let maximumPathBytes = Int(MAXPATHLEN) - 1

    static func observeRoot(
        configuration: CollectorRootConfiguration,
        testHooks: CollectorPOSIXRootEnumeratorTestHooks = .init()
    ) throws -> CollectorPOSIXRootBinding {
        let components = try validatedComponents(configuration)
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components, testHooks: testHooks)
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor, testHooks: testHooks) }
        let binding = CollectorPOSIXRootBinding(configuration: configuration, expectedIdentity: try identity(opened.info))
        // Reopen the configured route before publishing the observation. A
        // detached old fd is not proof that the current path still names it.
        try validateRoot(binding: binding, testHooks: testHooks)
        try Task.checkCancellation()
        return binding
    }

    static func validateRoot(
        binding: CollectorPOSIXRootBinding,
        testHooks: CollectorPOSIXRootEnumeratorTestHooks = .init()
    ) throws {
        let enumerator = try CollectorPOSIXRootEnumerator(binding: binding, testHooks: testHooks)
        let opened = try enumerator.openBoundDirectory(relativeComponents: [])
        defer { enumerator.closeDescriptor(opened.descriptor) }
        try Task.checkCancellation()
    }

    private let binding: CollectorPOSIXRootBinding
    private let testHooks: CollectorPOSIXRootEnumeratorTestHooks
    private let rootComponents: [String]

    init(
        binding: CollectorPOSIXRootBinding,
        testHooks: CollectorPOSIXRootEnumeratorTestHooks = .init()
    ) throws {
        let components = try Self.validatedComponents(binding.configuration)
        self.binding = binding
        self.testHooks = testHooks
        rootComponents = components
    }

    private static func validatedComponents(_ configuration: CollectorRootConfiguration) throws -> [String] {
        guard configuration.source == .codex || configuration.source == .claudeCode,
              !configuration.rootID.isEmpty, !configuration.rootID.contains("\0"), configuration.revision > 0 else {
            throw CollectorPOSIXEnumerationError.invalidBinding
        }
        return try CollectorPOSIXDirectoryAccess.components(configuration.rootPath)
    }

    func open(
        configuration: CollectorRootConfiguration,
        relativeDirectory: String
    ) throws -> any CollectorDirectoryCursor {
        let expected = binding.configuration
        guard configuration.rootID.utf8.elementsEqual(expected.rootID.utf8),
              configuration.rootPath.utf8.elementsEqual(expected.rootPath.utf8),
              configuration.source == expected.source, configuration.revision == expected.revision else {
            throw CollectorPOSIXEnumerationError.configurationMismatch
        }
        guard CollectorInventoryStore.isSafeRelativePath(relativeDirectory, allowRoot: true),
              relativeDirectory.utf8.count <= Self.maximumPathBytes,
              expected.rootPath.utf8.count + (relativeDirectory.isEmpty ? 0 : 1 + relativeDirectory.utf8.count) <= Self.maximumPathBytes else {
            throw CollectorPOSIXEnumerationError.unsafePath
        }
        let components = relativeDirectory.split(separator: "/").map(String.init)
        guard components.count <= Self.maximumRelativeDepth else { throw CollectorPOSIXEnumerationError.depthLimit }
        let opened = try openBoundDirectory(relativeComponents: components)
        var descriptor = opened.descriptor
        defer { if descriptor >= 0 { closeDescriptor(descriptor) } }
        if let code = testHooks.directoryStreamFailure?() {
            throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, code)
        }
        guard let stream = fdopendir(descriptor) else {
            throw CollectorPOSIXEnumerationError.io(.openDirectoryStream, errno)
        }
        // Ownership transfers exactly once. No raw close may follow fdopendir.
        descriptor = -1
        let cursor = Cursor(owner: self, stream: stream, components: components, initialInfo: opened.info)
        do {
            try testHooks.afterCursorOpened?(relativeDirectory, dirfd(stream))
            try cursor.validateDirectory()
            return cursor
        } catch {
            cursor.fail(error)
            throw error
        }
    }

    static func decodeEntryName(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty, bytes.count <= Int(MAXNAMLEN), !bytes.contains(0), !bytes.contains(0x2F),
              let name = String(data: bytes, encoding: .utf8), name.utf8.elementsEqual(bytes) else {
            throw CollectorPOSIXEnumerationError.invalidEntryName
        }
        return name
    }

    private func openBoundDirectory(relativeComponents: [String]) throws -> (descriptor: Int32, info: stat) {
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: rootComponents, testHooks: testHooks)
        var descriptor = opened.descriptor
        defer { if descriptor >= 0 { closeDescriptor(descriptor) } }
        guard try Self.identity(opened.info) == binding.expectedIdentity else {
            throw CollectorPOSIXEnumerationError.rootIdentityChanged
        }
        for component in relativeComponents {
            let next = try openComponent(component, parent: descriptor)
            closeDescriptor(descriptor)
            descriptor = next
        }
        let info = try directoryStat(descriptor)
        let result = descriptor
        descriptor = -1
        return (result, info)
    }

    private func openComponent(_ component: String, parent: Int32) throws -> Int32 {
        try CollectorPOSIXDirectoryAccess.openComponent(component, parent: parent, testHooks: testHooks)
    }

    private func closeDescriptor(_ descriptor: Int32) {
        CollectorPOSIXDirectoryAccess.close(descriptor, testHooks: testHooks)
    }

    private func directoryStat(_ descriptor: Int32) throws -> stat {
        try CollectorPOSIXDirectoryAccess.directoryStat(descriptor)
    }

    private static func identity(_ info: stat) throws -> CollectorPOSIXDirectoryIdentity {
        try CollectorPOSIXDirectoryAccess.identity(info)
    }

    private func selectedDirectory(_ components: [String]) -> Bool {
        if binding.configuration.source == .codex { return components.allSatisfy { !$0.hasPrefix(".") } }
        guard components.dropFirst().allSatisfy({ !$0.hasPrefix(".") }) else { return false }
        switch components.count {
        case 1: return true // Project directory names may start with a dot.
        case 2: return !components[1].hasSuffix(".jsonl")
        case 3: return components[2] == "subagents"
        case 4: return components[2] == "subagents" && components[3] == "workflows"
        case 5: return components[2] == "subagents" && components[3] == "workflows" && components[4].hasPrefix("wf_")
        default: return false
        }
    }

    private func selectedFile(_ components: [String]) -> Bool {
        guard let name = components.last, !name.hasPrefix("."), name.hasSuffix(".jsonl") else { return false }
        if binding.configuration.source == .codex {
            return name.hasPrefix("rollout-") && components.allSatisfy { !$0.hasPrefix(".") }
        }
        guard components.dropFirst().allSatisfy({ !$0.hasPrefix(".") }) else { return false }
        switch components.count {
        case 2: return true
        case 4: return components[2] == "subagents"
        case 6:
            return components[2] == "subagents" && components[3] == "workflows"
                && components[4].hasPrefix("wf_") && name.hasPrefix("agent-")
        default: return false
        }
    }

    private static func observation(_ info: stat, relativePath: String) throws -> CollectorObservedFile {
        func nanoseconds(_ value: timespec) throws -> Int64 {
            let (seconds, multiplyOverflow) = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let (result, addOverflow) = seconds.addingReportingOverflow(Int64(value.tv_nsec))
            guard !multiplyOverflow, !addOverflow else { throw CollectorPOSIXEnumerationError.io(.statEntry, EOVERFLOW) }
            return result
        }
        guard let inode = Int64(exactly: info.st_ino) else { throw CollectorPOSIXEnumerationError.io(.statEntry, EOVERFLOW) }
        let generation = try ArchiveSourceGeneration(
            device: Int64(info.st_dev), inode: inode, size: Int64(info.st_size),
            mtimeNs: nanoseconds(info.st_mtimespec), ctimeNs: nanoseconds(info.st_ctimespec), mode: Int64(info.st_mode)
        )
        // Metadata only: no body read, capture ID, hash, or privacy eligibility.
        let encoded = try ArchiveCanonicalJSON.encode(generation)
        return .init(relativePath: relativePath, observedGeneration: "stat-v1:" + String(decoding: encoded, as: UTF8.self))
    }

    private final class Cursor: CollectorDirectoryCursor {
        private let owner: CollectorPOSIXRootEnumerator
        private var stream: UnsafeMutablePointer<DIR>?
        private let components: [String]
        private let initialInfo: stat
        private var failure: Error?
        private var remainingDotEntries = 2

        init(owner: CollectorPOSIXRootEnumerator, stream: UnsafeMutablePointer<DIR>, components: [String], initialInfo: stat) {
            self.owner = owner
            self.stream = stream
            self.components = components
            self.initialInfo = initialInfo
        }

        deinit { closeStream() }

        func next() throws -> CollectorDirectoryEntry? {
            if let failure { throw failure }
            do {
                try Task.checkCancellation()
                guard let stream else { return nil }
                try validateDirectory()
                while true {
                    try Task.checkCancellation()
                    try owner.testHooks.beforeReadEntry?()
                    // Clear stale errno immediately before the native operation.
                    errno = 0
                    let entry: UnsafeMutablePointer<dirent>?
                    if let code = owner.testHooks.readDirectoryFailure?() {
                        entry = nil
                        errno = code
                    } else {
                        errno = 0
                        entry = readdir(stream)
                    }
                    let readError = errno
                    guard let entry else {
                        guard readError == 0 else { throw CollectorPOSIXEnumerationError.io(.readDirectory, readError) }
                        try owner.testHooks.afterReadEntry?(nil)
                        try validateDirectory()
                        closeStream()
                        return nil
                    }
                    var value = entry.pointee
                    let count = Int(value.d_namlen)
                    let bytes: Data = try withUnsafeBytes(of: &value.d_name) { buffer in
                        guard count > 0, count < buffer.count, buffer[count] == 0 else {
                            throw CollectorPOSIXEnumerationError.invalidEntryName
                        }
                        return Data(buffer.prefix(count))
                    }
                    let name = try CollectorPOSIXRootEnumerator.decodeEntryName(bytes)
                    try owner.testHooks.afterReadEntry?(name)
                    try Task.checkCancellation()
                    if name == "." || name == ".." {
                        guard remainingDotEntries > 0 else { throw CollectorPOSIXEnumerationError.directoryContentsChanged }
                        remainingDotEntries -= 1
                        try validateDirectory()
                        continue
                    }
                    let childComponents = components + [name]
                    let path = childComponents.joined(separator: "/")
                    guard owner.binding.configuration.rootPath.utf8.count + 1 + path.utf8.count <= CollectorPOSIXRootEnumerator.maximumPathBytes else {
                        throw CollectorPOSIXEnumerationError.unsafePath
                    }
                    var info = stat()
                    let result = name.withCString { fstatat(dirfd(stream), $0, &info, AT_SYMLINK_NOFOLLOW) }
                    guard result == 0 else { throw CollectorPOSIXEnumerationError.io(.statEntry, errno) }
                    let selected: CollectorDirectoryEntry
                    switch info.st_mode & S_IFMT {
                    case S_IFLNK: selected = .symlink(path)
                    case S_IFDIR:
                        if owner.selectedDirectory(childComponents) {
                            guard childComponents.count <= CollectorPOSIXRootEnumerator.maximumRelativeDepth else {
                                throw CollectorPOSIXEnumerationError.depthLimit
                            }
                            selected = .directory(path)
                        } else { selected = .ignored(path) }
                    case S_IFREG:
                        selected = owner.selectedFile(childComponents)
                            ? .file(try CollectorPOSIXRootEnumerator.observation(info, relativePath: path)) : .ignored(path)
                    default: selected = .ignored(path)
                    }
                    try validateDirectory()
                    return selected // Exactly one non-dot entry, including rejects.
                }
            } catch {
                fail(error)
                throw error
            }
        }

        fileprivate func validateDirectory() throws {
            try Task.checkCancellation()
            let current = try owner.openBoundDirectory(relativeComponents: components)
            defer { owner.closeDescriptor(current.descriptor) }
            guard try CollectorPOSIXRootEnumerator.identity(current.info) == CollectorPOSIXRootEnumerator.identity(initialInfo) else {
                throw CollectorPOSIXEnumerationError.directoryIdentityChanged
            }
            guard let stream else { throw CollectorPOSIXEnumerationError.directoryIdentityChanged }
            let streamInfo = try owner.directoryStat(dirfd(stream))
            guard try CollectorPOSIXRootEnumerator.identity(streamInfo) == CollectorPOSIXRootEnumerator.identity(initialInfo) else {
                throw CollectorPOSIXEnumerationError.directoryIdentityChanged
            }
            for info in [current.info, streamInfo] {
                guard info.st_mtimespec.tv_sec == initialInfo.st_mtimespec.tv_sec,
                      info.st_mtimespec.tv_nsec == initialInfo.st_mtimespec.tv_nsec,
                      info.st_ctimespec.tv_sec == initialInfo.st_ctimespec.tv_sec,
                      info.st_ctimespec.tv_nsec == initialInfo.st_ctimespec.tv_nsec else {
                    throw CollectorPOSIXEnumerationError.directoryContentsChanged
                }
            }
            try Task.checkCancellation()
        }

        fileprivate func fail(_ error: Error) {
            failure = error
            closeStream()
        }

        private func closeStream() {
            guard let stream else { return }
            self.stream = nil
            let descriptor = dirfd(stream)
            _ = closedir(stream)
            owner.testHooks.didCloseDescriptor?(descriptor, true)
        }
    }
}

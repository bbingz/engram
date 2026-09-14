import CryptoKit
import Darwin
#if !ENGRAM_COLLECTOR_CORE
import EngramCoreRead
#endif
import Foundation

public enum ExactSourceCapturerError: Error, Equatable, Sendable {
    case invalidMachineID(String)
    case machineIDMismatch(expected: String, actual: String)
    case ineligible(ArchiveLocatorClassification)
    case generationChanged
    case invalidMaximumByteCount
    case exceededMaximumByteCount(Int64)
    case existingCaptureConflict(String)
    case io(operation: String, code: Int32)
}

public struct ArchiveCaptureResult: Equatable, Sendable {
    public let capture: ArchiveCapture
    public let manifest: ArchiveSourceManifest

    public init(capture: ArchiveCapture, manifest: ArchiveSourceManifest) {
        self.capture = capture
        self.manifest = manifest
    }
}

struct ExactSourceCapturerTestHooks: Sendable {
    let maximumReadSize: Int?
    let afterStreamingBeforeFinalStat: (@Sendable (URL) throws -> Void)?

    init(
        maximumReadSize: Int? = nil,
        afterStreamingBeforeFinalStat: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.maximumReadSize = maximumReadSize
        self.afterStreamingBeforeFinalStat = afterStreamingBeforeFinalStat
    }
}

/// Sealed source bytes with their original provenance, never staging-file stat data.
public struct ArchiveCapturedFile: Equatable, Sendable {
    public let relativePath: String
    public let generation: ArchiveSourceGeneration
    public let bytes: Data

    public init(relativePath: String, generation: ArchiveSourceGeneration, bytes: Data) {
        self.relativePath = relativePath
        self.generation = generation
        self.bytes = bytes
    }
}

public struct ExactSourceCapturer: Sendable {
    private let cas: ImmutableArchiveCAS
    private let catalog: ArchiveCatalog
    private let descriptor: ArchiveSourceDescriptor
    private let testHooks: ExactSourceCapturerTestHooks

    public static func captureCursorModernFileSet(
        _ members: [ArchiveCapturedFile], locator: String, absentRelativePaths: [String],
        machineID: String, cas: ImmutableArchiveCAS, catalog: ArchiveCatalog,
        maximumByteCount: Int64? = nil
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        guard UUID(uuidString: machineID) != nil else { throw ExactSourceCapturerError.invalidMachineID(machineID) }
        let persistedMachineID = try catalog.machineID()
        guard persistedMachineID == machineID else {
            throw ExactSourceCapturerError.machineIDMismatch(expected: persistedMachineID, actual: machineID)
        }
        if let maximumByteCount, maximumByteCount < 0 { throw ExactSourceCapturerError.invalidMaximumByteCount }
        guard (1...4).contains(members.count), absentRelativePaths.count <= 2 else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorModernFileSet")
        }
        let ordered = members.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        var total: Int64 = 0
        for member in ordered {
            let next = total.addingReportingOverflow(Int64(member.bytes.count))
            guard !next.overflow else { throw ArchiveV2ValidationError.rawByteCountOverflow }
            total = next.partialValue
        }
        if let maximumByteCount, total > maximumByteCount {
            throw ExactSourceCapturerError.exceededMaximumByteCount(maximumByteCount)
        }
        // The caller already sealed the source. Do not reopen either the live
        // logical locator or a staged replica and substitute its file identity.
        var offset: Int64 = 0
        let entries = try ordered.map { member in
            try Task.checkCancellation()
            let entry = try ArchiveFileSetEntry(relativePath: member.relativePath, byteOffset: offset,
                rawByteCount: Int64(member.bytes.count), wholeSourceSHA256: ArchiveV2Hash.sha256(member.bytes),
                generation: member.generation)
            offset += Int64(member.bytes.count)
            return entry
        }
        guard let primary = entries.first(where: {
            locator.utf8.suffix($0.relativePath.utf8.count + 1).elementsEqual(("/" + $0.relativePath).utf8)
        }) else { throw ArchiveV2ValidationError.invalidValue(field: "cursorModernFileSet.locator") }
        let layout = try ArchiveReplayLayout(strategy: .fileSet, relativePaths: entries.map(\.relativePath),
            entrypointRelativePath: primary.relativePath, files: entries,
            absentRelativePaths: absentRelativePaths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        guard ArchiveSourceDescriptor.cursorModernSessionID(layout, locator: locator) != nil else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorModernFileSet")
        }
        var builder = FileSetChunkBuilder()
        defer { for staged in builder.staged { try? cas.discardStaged(staged) } }
        for member in ordered {
            try Task.checkCancellation()
            try builder.append(member.bytes, cas: cas)
        }
        try builder.finish(cas: cas)
        let digest = Self.hexDigest(builder.wholeHasher.finalize())
        let captureID = try fileSetCaptureID(machineID: machineID, source: .cursor, locator: locator,
            generation: primary.generation, wholeSourceSHA256: digest, replayLayout: layout)
        return try commitStructuredCapture(cas: cas, catalog: catalog, schemaVersion: 2,
            captureID: captureID, machineID: machineID, source: .cursor, locator: locator,
            generation: primary.generation, wholeSourceSHA256: digest, rawByteCount: total,
            chunks: builder.chunks, stagedChunks: builder.staged, replayLayout: layout)
    }

    public static func captureCursorLegacySession(
        _ session: ArchiveCursorLegacySession, machineID: String, cas: ImmutableArchiveCAS, catalog: ArchiveCatalog,
        maximumByteCount: Int64? = nil
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        guard UUID(uuidString: machineID) != nil else {
            throw ExactSourceCapturerError.invalidMachineID(machineID)
        }
        let persistedMachineID = try catalog.machineID()
        guard machineID == persistedMachineID else {
            throw ExactSourceCapturerError.machineIDMismatch(expected: persistedMachineID, actual: machineID)
        }
        if let maximumByteCount, maximumByteCount < 0 { throw ExactSourceCapturerError.invalidMaximumByteCount }
        let bodyBytes = try session.encodeCanonical()
        let context = try ArchiveCursorLegacyContext(session: session)
        let generation = session.databaseGeneration
        if let maximumByteCount {
            guard maximumByteCount >= 0 else { throw ExactSourceCapturerError.invalidMaximumByteCount }
            guard Int64(bodyBytes.count) <= maximumByteCount else {
                throw ExactSourceCapturerError.exceededMaximumByteCount(maximumByteCount)
            }
        }
        let replayLayout = try ArchiveReplayLayout(
            strategy: .singleFile, relativePaths: ["session.cursor-legacy.json"], cursorLegacySession: context
        )
        let locator = context.logicalLocator
        let wholeSourceSHA256 = ArchiveV2Hash.sha256(bodyBytes)
        let captureID = try cursorLegacySessionCaptureID(machineID: machineID, context: context,
            generation: generation, wholeSourceSHA256: wholeSourceSHA256)
        var chunks: [ArchiveChunkReference] = []
        var staged: [ImmutableArchiveCAS.StagedContent] = []
        defer { for chunk in staged { try? cas.discardStaged(chunk) } }
        var start = bodyBytes.startIndex
        while start < bodyBytes.endIndex {
            try Task.checkCancellation()
            let end = bodyBytes.index(start, offsetBy: min(Int(ArchiveSourceManifest.rawChunkSize),
                bodyBytes.distance(from: start, to: bodyBytes.endIndex)))
            let chunk = Data(bodyBytes[start..<end])
            let hash = ArchiveV2Hash.sha256(chunk)
            staged.append(try cas.stageObject(raw: chunk, expectedSHA256: hash))
            chunks.append(try ArchiveChunkReference(ordinal: chunks.count, rawSHA256: hash,
                rawByteCount: Int64(chunk.count)))
            start = end
        }
        return try commitStructuredCapture(cas: cas, catalog: catalog, schemaVersion: 6,
            captureID: captureID, machineID: machineID, source: .cursor, locator: locator,
            generation: generation, wholeSourceSHA256: wholeSourceSHA256,
            rawByteCount: Int64(bodyBytes.count), chunks: chunks, stagedChunks: staged, replayLayout: replayLayout)
    }

    public static func cursorLegacySessionCaptureID(
        machineID: String, context: ArchiveCursorLegacyContext, generation: ArchiveSourceGeneration,
        wholeSourceSHA256: String
    ) throws -> String {
        let replayLayout = try ArchiveReplayLayout(strategy: .singleFile,
            relativePaths: ["session.cursor-legacy.json"], cursorLegacySession: context)
        let identity = FileSetCaptureIdentity(machineID: machineID, source: SourceName.cursor.rawValue,
            locator: context.logicalLocator, generation: generation, wholeSourceSHA256: wholeSourceSHA256,
            replayLayout: replayLayout)
        var identityBytes = Data("engram.cursor-legacy-session.v1\0".utf8)
        identityBytes.append(try ArchiveCanonicalJSON.encode(identity))
        return ArchiveV2Hash.sha256(identityBytes)
    }

    public static func captureSQLiteSessionImage(
        _ image: Data, context: ArchiveSQLiteSessionContext, generation: ArchiveSourceGeneration,
        machineID: String, cas: ImmutableArchiveCAS, catalog: ArchiveCatalog,
        maximumByteCount: Int64? = nil
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        guard UUID(uuidString: machineID) != nil else {
            throw ExactSourceCapturerError.invalidMachineID(machineID)
        }
        let persistedMachineID = try catalog.machineID()
        guard machineID == persistedMachineID else {
            throw ExactSourceCapturerError.machineIDMismatch(expected: persistedMachineID, actual: machineID)
        }
        if let maximumByteCount {
            guard maximumByteCount >= 0 else { throw ExactSourceCapturerError.invalidMaximumByteCount }
            guard Int64(image.count) <= maximumByteCount else {
                throw ExactSourceCapturerError.exceededMaximumByteCount(maximumByteCount)
            }
        }
        let replayLayout = try ArchiveReplayLayout(
            strategy: .singleFile, relativePaths: ["session.sqlite"], sqliteSession: context
        )
        let locator = context.databaseLocator + "::" + context.nativeSessionID
        let wholeSourceSHA256 = ArchiveV2Hash.sha256(image)
        let captureID = try sqliteSessionImageCaptureID(machineID: machineID, context: context,
            generation: generation, wholeSourceSHA256: wholeSourceSHA256)
        var chunks: [ArchiveChunkReference] = []
        var staged: [ImmutableArchiveCAS.StagedContent] = []
        defer { for chunk in staged { try? cas.discardStaged(chunk) } }
        var start = image.startIndex
        while start < image.endIndex {
            try Task.checkCancellation()
            let end = image.index(start, offsetBy: min(Int(ArchiveSourceManifest.rawChunkSize),
                image.distance(from: start, to: image.endIndex)))
            let chunk = Data(image[start..<end])
            let hash = ArchiveV2Hash.sha256(chunk)
            staged.append(try cas.stageObject(raw: chunk, expectedSHA256: hash))
            chunks.append(try ArchiveChunkReference(ordinal: chunks.count, rawSHA256: hash,
                rawByteCount: Int64(chunk.count)))
            start = end
        }
        return try commitStructuredCapture(cas: cas, catalog: catalog, schemaVersion: 4,
            captureID: captureID, machineID: machineID, source: .opencode, locator: locator,
            generation: generation, wholeSourceSHA256: wholeSourceSHA256,
            rawByteCount: Int64(image.count), chunks: chunks, stagedChunks: staged, replayLayout: replayLayout)
    }

    public static func sqliteSessionImageCaptureID(
        machineID: String, context: ArchiveSQLiteSessionContext, generation: ArchiveSourceGeneration,
        wholeSourceSHA256: String
    ) throws -> String {
        let replayLayout = try ArchiveReplayLayout(
            strategy: .singleFile, relativePaths: ["session.sqlite"], sqliteSession: context
        )
        let locator = context.databaseLocator + "::" + context.nativeSessionID
        let identity = FileSetCaptureIdentity(machineID: machineID, source: SourceName.opencode.rawValue,
            locator: locator, generation: generation, wholeSourceSHA256: wholeSourceSHA256,
            replayLayout: replayLayout)
        // A derived database image has a distinct identity domain from exact source captures.
        var identityBytes = Data("engram.sqlite-session-image.v1\0".utf8)
        identityBytes.append(try ArchiveCanonicalJSON.encode(identity))
        return ArchiveV2Hash.sha256(identityBytes)
    }

    public init(
        cas: ImmutableArchiveCAS,
        catalog: ArchiveCatalog,
        descriptor: ArchiveSourceDescriptor
    ) {
        self.init(
            cas: cas,
            catalog: catalog,
            descriptor: descriptor,
            testHooks: ExactSourceCapturerTestHooks()
        )
    }

    init(
        cas: ImmutableArchiveCAS,
        catalog: ArchiveCatalog,
        descriptor: ArchiveSourceDescriptor,
        testHooks: ExactSourceCapturerTestHooks
    ) {
        self.cas = cas
        self.catalog = catalog
        self.descriptor = descriptor
        self.testHooks = testHooks
    }

    public func capture(
        source: SourceName,
        locator: String,
        machineID: String,
        maximumByteCount: Int64? = nil,
        expectedGeneration: ArchiveSourceGeneration? = nil
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        guard UUID(uuidString: machineID) != nil else {
            throw ExactSourceCapturerError.invalidMachineID(machineID)
        }
        let persistedMachineID = try catalog.machineID()
        guard machineID == persistedMachineID else {
            throw ExactSourceCapturerError.machineIDMismatch(
                expected: persistedMachineID,
                actual: machineID
            )
        }
        if descriptor.fileSetRoot != nil {
            return try captureDeclaredFileSet(
                source: source,
                locator: locator,
                machineID: machineID,
                maximumByteCount: maximumByteCount,
                expectedGeneration: expectedGeneration
            )
        }
        let classification = ArchiveLocatorClassifier.classify(
            descriptor: descriptor,
            enumeratedLocator: locator
        )
        guard case .declaredSingleFile(let sourceURL) = classification else {
            throw ExactSourceCapturerError.ineligible(classification)
        }

        let streamed = try streamStableSource(sourceURL, maximumByteCount: maximumByteCount,
            expectedGeneration: expectedGeneration)
        defer {
            for staged in streamed.stagedChunks {
                try? cas.discardStaged(staged)
            }
        }
        try Task.checkCancellation()
        let replayLayout = try descriptor.singleFileReplayLayout()
        let relative = replayLayout.relativePaths[0]
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        let normalizedLocator: String
        let antigravityCLI = source == .antigravity && parts.count == 4
            && parts.suffix(3) == [".system_generated", "logs", "transcript.jsonl"]
        let windsurfHook = source == .windsurf && parts.count == 1
            && ArchiveSourceDescriptor.windsurfHookNativeID(logicalLocator: locator).map { $0 + ".jsonl" == relative } == true
        if antigravityCLI || windsurfHook {
            // A remote CLI identity must not depend on the receiving host's
            // Foundation aliases or on whether the original source still exists.
            guard let canonical = ArchiveSourceDescriptor.fileSetAbsolutePath(locator),
                  canonical.utf8.elementsEqual(locator.utf8),
                  locator.utf8.suffix(relative.utf8.count + 1).elementsEqual(("/" + relative).utf8) else {
                throw ExactSourceCapturerError.ineligible(.unsafe("CLI locator does not match replay layout"))
            }
            normalizedLocator = locator
        } else {
            normalizedLocator = sourceURL.standardizedFileURL.path
        }
        let captureID = try Self.captureID(
            machineID: machineID,
            source: source,
            locator: normalizedLocator,
            generation: streamed.generation,
            wholeSourceSHA256: streamed.wholeSourceSHA256
        )

        if let existing = try catalog.capture(captureID: captureID) {
            guard ArchiveV2Hash.sha256(existing.unboundManifestBytes)
                == existing.unboundManifestSHA256 else {
                throw ExactSourceCapturerError.existingCaptureConflict(captureID)
            }
            let manifest = try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self,
                from: existing.unboundManifestBytes
            )
            guard manifest.sessionID == nil,
                  manifest.captureID == captureID,
                  manifest.machineID == machineID,
                  manifest.source == source.rawValue,
                  manifest.locator == normalizedLocator,
                  manifest.generation == streamed.generation,
                  manifest.wholeSourceSHA256 == streamed.wholeSourceSHA256,
                  manifest.rawByteCount == streamed.generation.size,
                  manifest.chunks == streamed.chunks,
                  manifest.replayLayout == replayLayout else {
                throw ExactSourceCapturerError.existingCaptureConflict(captureID)
            }
            try Task.checkCancellation()
            let stagedManifest = try cas.stageManifest(
                existing.unboundManifestBytes,
                expectedSHA256: existing.unboundManifestSHA256
            )
            defer { try? cas.discardStaged(stagedManifest) }
            for staged in streamed.stagedChunks {
                _ = try cas.publishStaged(staged)
            }
            _ = try cas.publishStaged(stagedManifest)
            return ArchiveCaptureResult(capture: existing, manifest: manifest)
        }

        let manifest = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: source.rawValue,
            locator: normalizedLocator,
            sessionID: nil,
            capturedAt: Self.currentTimestamp(),
            generation: streamed.generation,
            wholeSourceSHA256: streamed.wholeSourceSHA256,
            rawByteCount: streamed.generation.size,
            chunks: streamed.chunks,
            replayLayout: replayLayout
        )
        let canonicalBytes = try ArchiveCanonicalJSON.encode(manifest)
        let manifestSHA256 = ArchiveV2Hash.sha256(canonicalBytes)
        try Task.checkCancellation()
        let stagedManifest = try cas.stageManifest(
            canonicalBytes,
            expectedSHA256: manifestSHA256
        )
        defer { try? cas.discardStaged(stagedManifest) }
        let stagedContent = streamed.stagedChunks + [stagedManifest]
        for staged in stagedContent {
            _ = try cas.publishStaged(staged)
        }
        let capture = try catalog.recordCapture(canonicalManifestBytes: canonicalBytes)
        return ArchiveCaptureResult(capture: capture, manifest: manifest)
    }

    private func captureDeclaredFileSet(
        source: SourceName,
        locator: String,
        machineID: String,
        maximumByteCount: Int64?,
        expectedGeneration: ArchiveSourceGeneration?
    ) throws -> ArchiveCaptureResult {
        try Task.checkCancellation()
        if let maximumByteCount, maximumByteCount < 0 {
            throw ExactSourceCapturerError.invalidMaximumByteCount
        }
        guard let rootURL = descriptor.fileSetRoot,
              let normalizedLocator = ArchiveSourceDescriptor.fileSetAbsolutePath(locator),
              normalizedLocator.utf8.elementsEqual(descriptor.locator.utf8),
              descriptor.files.contains(where: {
                  $0.sourceURL.path.utf8.elementsEqual(normalizedLocator.utf8)
              }) else {
            throw ExactSourceCapturerError.ineligible(
                .unsafe("descriptor locator does not match enumerated locator")
            )
        }

        let present = descriptor.files.sorted {
            $0.replayRelativePath.utf8.lexicographicallyPrecedes($1.replayRelativePath.utf8)
        }
        let absent = descriptor.absentFiles.sorted {
            $0.replayRelativePath.utf8.lexicographicallyPrecedes($1.replayRelativePath.utf8)
        }
        guard let entrypoint = present.first(where: {
            $0.sourceURL.path.utf8.elementsEqual(normalizedLocator.utf8)
        })?.replayRelativePath else {
            throw ExactSourceCapturerError.ineligible(
                .unsafe("descriptor locator does not match enumerated locator")
            )
        }

        let session = FileSetSession()
        defer { session.closeAll() }
        let rootWalk = try openAbsoluteDirectory(rootURL.path, session: session)
        var opened: [OpenedFileSetMember] = []
        opened.reserveCapacity(present.count)
        for file in present {
            opened.append(try openPresentFile(file, rootFd: session.rootFd, rootURL: rootURL, session: session))
        }
        for file in absent {
            _ = try assertDeclaredAbsence(file, rootFd: session.rootFd, rootURL: rootURL)
        }

        var totalBytes: Int64 = 0
        for member in opened {
            let (next, overflow) = totalBytes.addingReportingOverflow(member.generation.size)
            guard !overflow else {
                throw Self.io("file-set-size", code: EOVERFLOW)
            }
            totalBytes = next
        }
        guard let primary = opened.first(where: {
            $0.file.sourceURL.path.utf8.elementsEqual(normalizedLocator.utf8)
        }) else {
            throw ExactSourceCapturerError.ineligible(
                .unsafe("descriptor locator does not match enumerated locator")
            )
        }
        if let expectedGeneration, primary.generation != expectedGeneration {
            throw ExactSourceCapturerError.generationChanged
        }
        let contextByteCount = Int64(descriptor.vscodeWorkspaceContext?.configurationData?.count ?? 0)
        let (budgetBytes, budgetOverflow) = totalBytes.addingReportingOverflow(contextByteCount)
        guard !budgetOverflow else { throw Self.io("file-set-size", code: EOVERFLOW) }
        if let maximumByteCount, budgetBytes > maximumByteCount {
            throw ExactSourceCapturerError.exceededMaximumByteCount(maximumByteCount)
        }
        let vscodeWorkspacePath = descriptor.vscodeWorkspaceContext == nil ? nil
            : entrypoint.split(separator: "/").first.map { String($0) + "/workspace.json" }
        if let vscodeWorkspacePath, let workspace = opened.first(where: {
            $0.file.replayRelativePath.utf8.elementsEqual(vscodeWorkspacePath.utf8)
        }), workspace.generation.size > ArchiveVSCodeWorkspaceContext.maximumContextBytes {
            throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.workspace")
        }
        var vscodeWorkspaceBytes: Data?
        var builder = FileSetChunkBuilder()
        var entries: [ArchiveFileSetEntry] = []
        var completed = false
        defer {
            if !completed {
                for staged in builder.staged {
                    try? cas.discardStaged(staged)
                }
            }
        }
        entries.reserveCapacity(opened.count)
        var byteOffset: Int64 = 0
        for member in opened {
            try Task.checkCancellation()
            let retainWorkspace = vscodeWorkspacePath.map {
                member.file.replayRelativePath.utf8.elementsEqual($0.utf8)
            } ?? false
            var retainedBytes: Data? = retainWorkspace ? Data() : nil
            let digest = try streamOpenedFile(member, into: &builder, retainingInto: &retainedBytes)
            if retainWorkspace { vscodeWorkspaceBytes = retainedBytes }
            try testHooks.afterStreamingBeforeFinalStat?(member.file.sourceURL)
            try Task.checkCancellation()
            let after = try Self.generation(fd: member.fd)
            guard after == member.generation else {
                throw ExactSourceCapturerError.generationChanged
            }
            entries.append(
                try ArchiveFileSetEntry(
                    relativePath: member.file.replayRelativePath,
                    byteOffset: byteOffset,
                    rawByteCount: member.generation.size,
                    wholeSourceSHA256: digest,
                    generation: member.generation
                )
            )
            let (nextOffset, overflow) = byteOffset.addingReportingOverflow(member.generation.size)
            guard !overflow else {
                throw Self.io("file-set-offset", code: EOVERFLOW)
            }
            byteOffset = nextOffset
        }
        try descriptor.vscodeWorkspaceContext?.validateWorkspaceData(vscodeWorkspaceBytes)
        try builder.finish(cas: cas)
        try revalidateFileSet(
            session: session,
            rootWalk: rootWalk,
            rootURL: rootURL,
            opened: opened,
            absentFiles: absent
        )
        guard byteOffset == totalBytes else {
            throw ExactSourceCapturerError.generationChanged
        }

        let replayLayout = try ArchiveReplayLayout(
            strategy: .fileSet,
            relativePaths: entries.map(\.relativePath),
            entrypointRelativePath: entrypoint,
            files: entries,
            absentRelativePaths: absent.map(\.replayRelativePath),
            vscodeWorkspaceContext: descriptor.vscodeWorkspaceContext,
            geminiProjectContext: descriptor.geminiProjectContext,
            kimiProjectContext: descriptor.kimiProjectContext
        )
        let wholeSourceSHA256 = Self.hexDigest(builder.wholeHasher.finalize())
        let captureID = try Self.fileSetCaptureID(
            machineID: machineID,
            source: source,
            locator: normalizedLocator,
            generation: primary.generation,
            wholeSourceSHA256: wholeSourceSHA256,
            replayLayout: replayLayout
        )
        try Task.checkCancellation()
        let schemaVersion: Int
        if replayLayout.vscodeWorkspaceContext != nil {
            schemaVersion = 7
        } else if replayLayout.kimiProjectContext != nil {
            schemaVersion = 5
        } else if replayLayout.geminiProjectContext != nil {
            schemaVersion = 3
        } else {
            schemaVersion = 2
        }
        let result = try Self.commitStructuredCapture(
            cas: cas, catalog: catalog,
            schemaVersion: schemaVersion,
            captureID: captureID,
            machineID: machineID,
            source: source,
            locator: normalizedLocator,
            generation: primary.generation,
            wholeSourceSHA256: wholeSourceSHA256,
            rawByteCount: totalBytes,
            chunks: builder.chunks,
            stagedChunks: builder.staged,
            replayLayout: replayLayout
        )
        completed = true
        return result
    }

    private struct DirectoryIdentity: Equatable {
        let device: Int64
        let inode: Int64
    }

    private struct RelativeWalk: Equatable {
        let components: [String]
        let directoryIdentities: [DirectoryIdentity]
    }

    private struct RootWalk {
        let components: [String]
        let identities: [DirectoryIdentity]
        let rootIdentity: DirectoryIdentity
    }

    private struct OpenedFileSetMember {
        let file: ArchiveSourceFileDescriptor
        let fd: Int32
        let generation: ArchiveSourceGeneration
        let walk: RelativeWalk
    }

    private final class FileSetSession {
        var rootFd: Int32 = -1
        var fileFds: [Int32] = []

        func closeAll() {
            for fd in fileFds where fd >= 0 {
                _ = Darwin.close(fd)
            }
            fileFds.removeAll()
            if rootFd >= 0 {
                _ = Darwin.close(rootFd)
                rootFd = -1
            }
        }

        deinit { closeAll() }
    }

    private struct FileSetChunkBuilder {
        var wholeHasher = SHA256()
        var pending = Data()
        var chunks: [ArchiveChunkReference] = []
        var staged: [ImmutableArchiveCAS.StagedContent] = []

        mutating func append(_ data: Data, cas: ImmutableArchiveCAS) throws {
            guard !data.isEmpty else { return }
            wholeHasher.update(data: data)
            var start = data.startIndex
            while start < data.endIndex {
                let room = Int(ArchiveSourceManifest.rawChunkSize) - pending.count
                let take = min(room, data.distance(from: start, to: data.endIndex))
                let end = data.index(start, offsetBy: take)
                pending.append(data[start..<end])
                start = end
                if Int64(pending.count) == ArchiveSourceManifest.rawChunkSize {
                    try flush(cas: cas)
                }
            }
        }

        mutating func finish(cas: ImmutableArchiveCAS) throws {
            if !pending.isEmpty {
                try flush(cas: cas)
            }
        }

        private mutating func flush(cas: ImmutableArchiveCAS) throws {
            let rawSHA256 = ArchiveV2Hash.sha256(pending)
            staged.append(try cas.stageObject(raw: pending, expectedSHA256: rawSHA256))
            chunks.append(
                try ArchiveChunkReference(
                    ordinal: chunks.count,
                    rawSHA256: rawSHA256,
                    rawByteCount: Int64(pending.count)
                )
            )
            pending = Data()
        }
    }

    private func openAbsoluteDirectory(_ path: String, session: FileSetSession) throws -> RootWalk {
        let components = try Self.absoluteComponents(path)
        var fd = try Self.openDirectory(parent: AT_FDCWD, name: "/")
        var identities: [DirectoryIdentity] = []
        do {
            for component in components {
                try Task.checkCancellation()
                let next = try Self.openDirectory(parent: fd, name: component)
                let identity: DirectoryIdentity
                do {
                    identity = try Self.directoryIdentity(fd: next)
                    try Self.fenceNamedDirectory(parent: fd, name: component, expected: identity)
                } catch {
                    _ = Darwin.close(next)
                    throw error
                }
                _ = Darwin.close(fd)
                fd = next
                identities.append(identity)
            }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
        session.rootFd = fd
        guard let rootIdentity = identities.last else {
            _ = Darwin.close(fd)
            session.rootFd = -1
            throw ExactSourceCapturerError.ineligible(.unsafe("invalid file-set root"))
        }
        return RootWalk(components: components, identities: identities, rootIdentity: rootIdentity)
    }

    private func openPresentFile(
        _ file: ArchiveSourceFileDescriptor,
        rootFd: Int32,
        rootURL: URL,
        session: FileSetSession
    ) throws -> OpenedFileSetMember {
        try Task.checkCancellation()
        let components = try Self.relativeComponents(file.replayRelativePath)
        guard let leaf = components.last else {
            throw ExactSourceCapturerError.ineligible(.unsafe("invalid relative path"))
        }
        guard Self.fileSetPath(rootURL, relative: file.replayRelativePath)
            .utf8.elementsEqual(file.sourceURL.path.utf8) else {
            throw ExactSourceCapturerError.ineligible(
                .unsafe("descriptor file does not match enumerated locator")
            )
        }
        var parent = rootFd
        var openedDirectories: [Int32] = []
        var directoryIdentities: [DirectoryIdentity] = []
        defer {
            for directory in openedDirectories {
                _ = Darwin.close(directory)
            }
        }
        for directoryName in components.dropLast() {
            try Task.checkCancellation()
            let next = try Self.openDirectory(parent: parent, name: directoryName)
            openedDirectories.append(next)
            let identity = try Self.directoryIdentity(fd: next)
            try Self.fenceNamedDirectory(parent: parent, name: directoryName, expected: identity)
            parent = next
            directoryIdentities.append(identity)
        }
        let fd = try Self.openRegularFile(parent: parent, name: leaf)
        do {
            let generation = try Self.secureGeneration(fd: fd, parent: parent, name: leaf)
            session.fileFds.append(fd)
            return OpenedFileSetMember(
                file: file,
                fd: fd,
                generation: generation,
                walk: RelativeWalk(components: components, directoryIdentities: directoryIdentities)
            )
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private func assertDeclaredAbsence(
        _ file: ArchiveSourceFileDescriptor,
        rootFd: Int32,
        rootURL: URL
    ) throws -> RelativeWalk {
        try Task.checkCancellation()
        let components = try Self.relativeComponents(file.replayRelativePath)
        guard let leaf = components.last else {
            throw ExactSourceCapturerError.ineligible(.unsafe("invalid relative path"))
        }
        guard Self.fileSetPath(rootURL, relative: file.replayRelativePath)
            .utf8.elementsEqual(file.sourceURL.path.utf8) else {
            throw ExactSourceCapturerError.ineligible(
                .unsafe("descriptor file does not match enumerated locator")
            )
        }
        var parent = rootFd
        var openedDirectories: [Int32] = []
        var directoryIdentities: [DirectoryIdentity] = []
        defer {
            for directory in openedDirectories {
                _ = Darwin.close(directory)
            }
        }
        do {
            for directoryName in components.dropLast() {
                try Task.checkCancellation()
                let next = try Self.openDirectory(parent: parent, name: directoryName)
                openedDirectories.append(next)
                let identity = try Self.directoryIdentity(fd: next)
                try Self.fenceNamedDirectory(parent: parent, name: directoryName, expected: identity)
                parent = next
                directoryIdentities.append(identity)
            }
            try Self.requireAbsentLeaf(parent: parent, name: leaf)
        } catch ExactSourceCapturerError.ineligible(.missing) where !components.dropLast().isEmpty {
            return RelativeWalk(components: components, directoryIdentities: directoryIdentities)
        }
        return RelativeWalk(components: components, directoryIdentities: directoryIdentities)
    }

    private func streamOpenedFile(
        _ member: OpenedFileSetMember,
        into builder: inout FileSetChunkBuilder,
        retainingInto retainedBytes: inout Data?
    ) throws -> String {
        var fileHasher = SHA256()
        var remaining = member.generation.size
        while remaining > 0 {
            try Task.checkCancellation()
            let cap = testHooks.maximumReadSize ?? Int(ArchiveSourceManifest.rawChunkSize)
            let requested = Int(min(remaining, Int64(max(cap, 1))))
            var buffer = Data(count: requested)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(member.fd, base, requested)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw count == 0
                    ? ExactSourceCapturerError.generationChanged
                    : Self.io("read-source", code: errno)
            }
            buffer.removeSubrange(count..<buffer.count)
            fileHasher.update(data: buffer)
            retainedBytes?.append(buffer)
            try builder.append(buffer, cas: cas)
            remaining -= Int64(count)
        }
        return Self.hexDigest(fileHasher.finalize())
    }

    private func revalidateFileSet(
        session: FileSetSession,
        rootWalk: RootWalk,
        rootURL: URL,
        opened: [OpenedFileSetMember],
        absentFiles: [ArchiveSourceFileDescriptor]
    ) throws {
        try Task.checkCancellation()
        guard session.rootFd >= 0,
              try Self.directoryIdentity(fd: session.rootFd) == rootWalk.rootIdentity else {
            throw ExactSourceCapturerError.generationChanged
        }
        try verifyAbsoluteDirectory(rootWalk)
        for member in opened {
            try Task.checkCancellation()
            do {
                let after = try Self.generation(fd: member.fd)
                guard after == member.generation else {
                    throw ExactSourceCapturerError.generationChanged
                }
                try verifyPresentNamedEntry(member, rootFd: session.rootFd)
            } catch ExactSourceCapturerError.ineligible {
                throw ExactSourceCapturerError.generationChanged
            }
        }
        for file in absentFiles {
            try Task.checkCancellation()
            do {
                _ = try assertDeclaredAbsence(file, rootFd: session.rootFd, rootURL: rootURL)
            } catch ExactSourceCapturerError.ineligible {
                throw ExactSourceCapturerError.generationChanged
            }
        }
    }

    private func verifyAbsoluteDirectory(_ walk: RootWalk) throws {
        var fd = try Self.openDirectory(parent: AT_FDCWD, name: "/")
        defer { _ = Darwin.close(fd) }
        for (component, expected) in zip(walk.components, walk.identities) {
            try Task.checkCancellation()
            let next = try Self.openDirectory(parent: fd, name: component)
            let identity: DirectoryIdentity
            do {
                identity = try Self.directoryIdentity(fd: next)
                try Self.fenceNamedDirectory(parent: fd, name: component, expected: expected)
                guard identity == expected else {
                    throw ExactSourceCapturerError.generationChanged
                }
            } catch {
                _ = Darwin.close(next)
                throw error
            }
            _ = Darwin.close(fd)
            fd = next
        }
    }

    private func verifyPresentNamedEntry(_ member: OpenedFileSetMember, rootFd: Int32) throws {
        let components = member.walk.components
        guard let leaf = components.last else {
            throw ExactSourceCapturerError.generationChanged
        }
        var parent = rootFd
        var openedDirectories: [Int32] = []
        defer {
            for directory in openedDirectories {
                _ = Darwin.close(directory)
            }
        }
        for (directoryName, expected) in zip(components.dropLast(), member.walk.directoryIdentities) {
            try Task.checkCancellation()
            let next = try Self.openDirectory(parent: parent, name: directoryName)
            openedDirectories.append(next)
            let identity = try Self.directoryIdentity(fd: next)
            try Self.fenceNamedDirectory(parent: parent, name: directoryName, expected: expected)
            guard identity == expected else {
                throw ExactSourceCapturerError.generationChanged
            }
            parent = next
        }
        let named = try Self.secureGeneration(fd: member.fd, parent: parent, name: leaf)
        guard named == member.generation else {
            throw ExactSourceCapturerError.generationChanged
        }
    }

    private static func commitStructuredCapture(
        cas: ImmutableArchiveCAS, catalog: ArchiveCatalog, schemaVersion: Int,
        captureID: String,
        machineID: String,
        source: SourceName,
        locator: String,
        generation: ArchiveSourceGeneration,
        wholeSourceSHA256: String,
        rawByteCount: Int64,
        chunks: [ArchiveChunkReference],
        stagedChunks: [ImmutableArchiveCAS.StagedContent],
        replayLayout: ArchiveReplayLayout
    ) throws -> ArchiveCaptureResult {
        if let existing = try catalog.capture(captureID: captureID) {
            guard ArchiveV2Hash.sha256(existing.unboundManifestBytes)
                == existing.unboundManifestSHA256 else {
                throw ExactSourceCapturerError.existingCaptureConflict(captureID)
            }
            let manifest = try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self,
                from: existing.unboundManifestBytes
            )
            guard manifest.sessionID == nil,
                  manifest.schemaVersion == schemaVersion,
                  manifest.captureID == captureID,
                  manifest.machineID == machineID,
                  manifest.source == source.rawValue,
                  manifest.locator == locator,
                  manifest.generation == generation,
                  manifest.wholeSourceSHA256 == wholeSourceSHA256,
                  manifest.rawByteCount == rawByteCount,
                  manifest.chunks == chunks,
                  manifest.replayLayout == replayLayout else {
                throw ExactSourceCapturerError.existingCaptureConflict(captureID)
            }
            try Task.checkCancellation()
            let stagedManifest = try cas.stageManifest(
                existing.unboundManifestBytes,
                expectedSHA256: existing.unboundManifestSHA256
            )
            defer { try? cas.discardStaged(stagedManifest) }
            for staged in stagedChunks {
                _ = try cas.publishStaged(staged)
            }
            _ = try cas.publishStaged(stagedManifest)
            return ArchiveCaptureResult(capture: existing, manifest: manifest)
        }

        let manifest = try ArchiveSourceManifest(
            schemaVersion: schemaVersion,
            captureID: captureID,
            machineID: machineID,
            source: source.rawValue,
            locator: locator,
            sessionID: nil,
            capturedAt: Self.currentTimestamp(),
            generation: generation,
            wholeSourceSHA256: wholeSourceSHA256,
            rawByteCount: rawByteCount,
            chunks: chunks,
            replayLayout: replayLayout
        )
        let canonicalBytes = try ArchiveCanonicalJSON.encode(manifest)
        let manifestSHA256 = ArchiveV2Hash.sha256(canonicalBytes)
        try Task.checkCancellation()
        let stagedManifest = try cas.stageManifest(
            canonicalBytes,
            expectedSHA256: manifestSHA256
        )
        defer { try? cas.discardStaged(stagedManifest) }
        for staged in stagedChunks + [stagedManifest] {
            _ = try cas.publishStaged(staged)
        }
        let capture = try catalog.recordCapture(canonicalManifestBytes: canonicalBytes)
        return ArchiveCaptureResult(capture: capture, manifest: manifest)
    }

    struct StableSourceRead: Equatable, Sendable {
        let generation: ArchiveSourceGeneration
        let wholeSourceSHA256: String
        let chunks: [ArchiveChunkReference]
        let stagedChunks: [ImmutableArchiveCAS.StagedContent]
    }

    func streamStableSource(
        _ sourceURL: URL,
        maximumByteCount: Int64? = nil,
        expectedGeneration: ArchiveSourceGeneration? = nil
    ) throws -> StableSourceRead {
        try Task.checkCancellation()
        if let maximumByteCount, maximumByteCount < 0 {
            throw ExactSourceCapturerError.invalidMaximumByteCount
        }
        // O_NONBLOCK closes the lstat/open race where a regular file is
        // replaced by a FIFO. It has no effect on regular-file reads, and the
        // immediate fstat gate below still rejects every non-regular object.
        let fd = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            let openError = errno
            if openError == ENOENT {
                throw ExactSourceCapturerError.ineligible(.missing)
            }
            if openError == ELOOP {
                throw ExactSourceCapturerError.ineligible(.unsafe("symlink locator"))
            }
            throw Self.io("open-source", code: openError)
        }
        defer { _ = Darwin.close(fd) }

        let before = try Self.secureGeneration(fd: fd, path: sourceURL.path)
        // Admission is checked against this open descriptor, before allocation
        // or staging. A caller's earlier path stat is not a transfer budget.
        if let expectedGeneration, before != expectedGeneration {
            throw ExactSourceCapturerError.generationChanged
        }
        if let maximumByteCount, before.size > maximumByteCount {
            throw ExactSourceCapturerError.exceededMaximumByteCount(maximumByteCount)
        }
        var remaining = before.size
        var wholeHasher = SHA256()
        var chunks: [ArchiveChunkReference] = []
        var stagedChunks: [ImmutableArchiveCAS.StagedContent] = []
        var completed = false
        defer {
            if !completed {
                for staged in stagedChunks {
                    try? cas.discardStaged(staged)
                }
            }
        }
        var ordinal = 0

        while remaining > 0 {
            try Task.checkCancellation()
            let expected = Int(min(remaining, ArchiveSourceManifest.rawChunkSize))
            var chunk = Data(count: expected)
            var filled = 0
            while filled < expected {
                try Task.checkCancellation()
                let requested = min(
                    expected - filled,
                    max(testHooks.maximumReadSize ?? (expected - filled), 1)
                )
                let count = chunk.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let base = rawBuffer.baseAddress else { return 0 }
                    return Darwin.read(fd, base.advanced(by: filled), requested)
                }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    if count == 0 {
                        throw ExactSourceCapturerError.generationChanged
                    }
                    throw Self.io("read-source", code: errno)
                }
                filled += count
            }

            wholeHasher.update(data: chunk)
            let rawSHA256 = ArchiveV2Hash.sha256(chunk)
            stagedChunks.append(
                try cas.stageObject(raw: chunk, expectedSHA256: rawSHA256)
            )
            chunks.append(
                try ArchiveChunkReference(
                    ordinal: ordinal,
                    rawSHA256: rawSHA256,
                    rawByteCount: Int64(chunk.count)
                )
            )
            ordinal += 1
            remaining -= Int64(chunk.count)
        }

        try testHooks.afterStreamingBeforeFinalStat?(sourceURL)
        try Task.checkCancellation()
        let after = try Self.generation(fd: fd)
        var pathInfo = stat()
        guard Darwin.lstat(sourceURL.path, &pathInfo) == 0 else {
            throw ExactSourceCapturerError.generationChanged
        }
        let pathGeneration = try Self.generation(info: pathInfo)
        guard before == after,
              after == pathGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }

        let result = StableSourceRead(
            generation: before,
            wholeSourceSHA256: Self.hexDigest(wholeHasher.finalize()),
            chunks: chunks,
            stagedChunks: stagedChunks
        )
        completed = true
        return result
    }

    static func verify(
        sourceURL: URL,
        expectedGeneration: ArchiveSourceGeneration,
        expectedWholeSourceSHA256: String
    ) throws {
        try Task.checkCancellation()
        let fd = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw ExactSourceCapturerError.generationChanged
        }
        defer { _ = Darwin.close(fd) }
        let before: ArchiveSourceGeneration
        do {
            before = try secureGeneration(fd: fd, path: sourceURL.path)
        } catch ExactSourceCapturerError.ineligible,
                ExactSourceCapturerError.generationChanged {
            throw ExactSourceCapturerError.generationChanged
        }
        guard before == expectedGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }

        var hasher = SHA256()
        var remaining = before.size
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            try Task.checkCancellation()
            let request = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, request)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw count == 0
                    ? ExactSourceCapturerError.generationChanged
                    : Self.io("read-source-verify", code: errno)
            }
            hasher.update(data: Data(buffer[0..<count]))
            remaining -= Int64(count)
        }
        try Task.checkCancellation()
        let after = try generation(fd: fd)
        var pathInfo = stat()
        guard Darwin.lstat(sourceURL.path, &pathInfo) == 0,
              let pathGeneration = try? generation(info: pathInfo),
              before == after,
              after == pathGeneration,
              hexDigest(hasher.finalize()) == expectedWholeSourceSHA256 else {
            throw ExactSourceCapturerError.generationChanged
        }
    }

    private static func secureGeneration(fd: Int32, path: String) throws -> ArchiveSourceGeneration {
        let descriptorGeneration = try generation(fd: fd)
        var pathInfo = stat()
        guard Darwin.lstat(path, &pathInfo) == 0 else {
            throw ExactSourceCapturerError.generationChanged
        }
        let pathGeneration = try generation(info: pathInfo)
        guard descriptorGeneration == pathGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }
        return descriptorGeneration
    }

    private static func secureGeneration(fd: Int32, parent: Int32, name: String) throws -> ArchiveSourceGeneration {
        let descriptorGeneration = try generation(fd: fd)
        var pathInfo = stat()
        let named = name.withCString { Darwin.fstatat(parent, $0, &pathInfo, AT_SYMLINK_NOFOLLOW) }
        guard named == 0 else {
            throw ExactSourceCapturerError.generationChanged
        }
        let pathGeneration = try generation(info: pathInfo)
        guard descriptorGeneration == pathGeneration else {
            throw ExactSourceCapturerError.generationChanged
        }
        return descriptorGeneration
    }

    private static func fileSetPath(_ rootURL: URL, relative: String) -> String {
        let root = ArchiveSourceDescriptor.fileSetAbsolutePath(rootURL.path) ?? rootURL.path
        return root + "/" + relative
    }

    private static func absoluteComponents(_ path: String) throws -> [String] {
        guard let normalized = ArchiveSourceDescriptor.fileSetAbsolutePath(path),
              normalized != "/" else {
            throw ExactSourceCapturerError.ineligible(.unsafe("invalid file-set root"))
        }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "",
              parts.count > 1,
              parts.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0)
              }) else {
            throw ExactSourceCapturerError.ineligible(.unsafe("invalid file-set root"))
        }
        return Array(parts.dropFirst())
    }

    private static func relativeComponents(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) && !$0.hasPrefix("/")
              }) else {
            throw ExactSourceCapturerError.ineligible(.unsafe("invalid relative path"))
        }
        return parts
    }

    private static func openDirectory(parent: Int32, name: String) throws -> Int32 {
        try Task.checkCancellation()
        let fd = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw openFailure("open-directory", errno) }
        return fd
    }

    private static func openRegularFile(parent: Int32, name: String) throws -> Int32 {
        try Task.checkCancellation()
        let fd = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw openFailure("open-source", errno) }
        return fd
    }

    private static func directoryIdentity(fd: Int32) throws -> DirectoryIdentity {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw io("fstat-directory", code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ExactSourceCapturerError.ineligible(.unsafe("non-directory ancestor"))
        }
        guard let inode = Int64(exactly: info.st_ino) else {
            throw io("fstat-directory", code: EOVERFLOW)
        }
        return DirectoryIdentity(device: Int64(info.st_dev), inode: inode)
    }

    private static func fenceNamedDirectory(
        parent: Int32, name: String, expected: DirectoryIdentity
    ) throws {
        var info = stat()
        let named = name.withCString { Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        guard named == 0 else { throw openFailure("fstatat-directory", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ExactSourceCapturerError.ineligible(.unsafe("non-directory ancestor"))
        }
        guard let inode = Int64(exactly: info.st_ino),
              DirectoryIdentity(device: Int64(info.st_dev), inode: inode) == expected else {
            throw ExactSourceCapturerError.generationChanged
        }
    }

    private static func requireAbsentLeaf(parent: Int32, name: String) throws {
        var info = stat()
        let named = name.withCString { Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if named == 0 {
            throw ExactSourceCapturerError.generationChanged
        }
        if errno == ENOENT {
            return
        }
        throw openFailure("fstatat-absent", errno)
    }

    private static func openFailure(_ operation: String, _ code: Int32) -> ExactSourceCapturerError {
        if code == ENOENT {
            return .ineligible(.missing)
        }
        if code == ELOOP {
            return .ineligible(.unsafe("symlink locator"))
        }
        if code == ENOTDIR {
            return .ineligible(.unsafe("non-directory ancestor"))
        }
        return io(operation, code: code)
    }

    private static func generation(fd: Int32) throws -> ArchiveSourceGeneration {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw io("fstat-source", code: errno)
        }
        return try generation(info: info)
    }

    private static func generation(info: stat) throws -> ArchiveSourceGeneration {
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ExactSourceCapturerError.ineligible(.unsafe("non-regular locator"))
        }
        return try ArchiveSourceGeneration(
            device: Int64(info.st_dev),
            inode: Int64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: try nanoseconds(info.st_mtimespec, operation: "mtime"),
            ctimeNs: try nanoseconds(info.st_ctimespec, operation: "ctime"),
            mode: Int64(info.st_mode)
        )
    }

    private struct CaptureIdentity: Codable {
        let machineID: String
        let source: String
        let locator: String
        let generation: ArchiveSourceGeneration
        let wholeSourceSHA256: String
    }

    private static func captureID(
        machineID: String,
        source: SourceName,
        locator: String,
        generation: ArchiveSourceGeneration,
        wholeSourceSHA256: String
    ) throws -> String {
        let identity = CaptureIdentity(
            machineID: machineID,
            source: source.rawValue,
            locator: locator,
            generation: generation,
            wholeSourceSHA256: wholeSourceSHA256
        )
        return ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(identity))
    }

    private struct FileSetCaptureIdentity: Codable {
        let machineID: String
        let source: String
        let locator: String
        let generation: ArchiveSourceGeneration
        let wholeSourceSHA256: String
        let replayLayout: ArchiveReplayLayout
    }

    private static func fileSetCaptureID(
        machineID: String,
        source: SourceName,
        locator: String,
        generation: ArchiveSourceGeneration,
        wholeSourceSHA256: String,
        replayLayout: ArchiveReplayLayout
    ) throws -> String {
        let identity = FileSetCaptureIdentity(
            machineID: machineID,
            source: source.rawValue,
            locator: locator,
            generation: generation,
            wholeSourceSHA256: wholeSourceSHA256,
            replayLayout: replayLayout
        )
        return ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(identity))
    }

    private static func nanoseconds(_ value: timespec, operation: String) throws -> Int64 {
        let (seconds, multiplyOverflow) = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let (result, addOverflow) = seconds.addingReportingOverflow(Int64(value.tv_nsec))
        guard !multiplyOverflow, !addOverflow else {
            throw io("\(operation)-overflow", code: EOVERFLOW)
        }
        return result
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func io(_ operation: String, code: Int32) -> ExactSourceCapturerError {
        .io(operation: operation, code: code)
    }
}

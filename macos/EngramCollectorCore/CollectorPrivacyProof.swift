import CryptoKit
import Foundation

public struct CollectorPrivacyLimits: Equatable, Sendable {
    public let maxSourceBytes: Int64
    public let maxLineBytes: Int
    public let maxRecords: Int
    public let maxProjectRoots: Int
    public let maxTotalProjectRootBytes: Int

    public init(
        maxSourceBytes: Int64 = 256 * 1024 * 1024,
        maxLineBytes: Int = 1024 * 1024,
        maxRecords: Int = 1_000_000,
        maxProjectRoots: Int = 64,
        maxTotalProjectRootBytes: Int = 65536
    ) {
        self.maxSourceBytes = maxSourceBytes
        self.maxLineBytes = maxLineBytes
        self.maxRecords = maxRecords
        self.maxProjectRoots = maxProjectRoots
        self.maxTotalProjectRootBytes = maxTotalProjectRootBytes
    }
}

public struct CollectorPrivacyPolicy: Equatable, Sendable {
    public let revision: Int64
    public let excludedProjectRoots: [String]
    public let allowedSources: Set<SourceName>

    public init(revision: Int64, excludedProjectRoots: [String], allowedSources: Set<SourceName> = [.claudeCode, .codex]) throws {
        guard revision > 0,
              excludedProjectRoots.allSatisfy({
                  SourceMetadataProjection.normalizedProjectRoot($0) != nil
                      && URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == $0
              }) else {
            throw CollectorPrivacyPolicyError.invalidPolicy
        }
        self.revision = revision
        self.excludedProjectRoots = Array(Set(excludedProjectRoots)).sorted()
        self.allowedSources = allowedSources
    }

    public func sha256() throws -> String {
        struct CanonicalPolicy: Encodable {
            let revision: Int64
            let excludedProjectRoots: [String]
            let allowedSources: [String]
        }
        return ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(CanonicalPolicy(
            revision: revision,
            excludedProjectRoots: excludedProjectRoots,
            allowedSources: allowedSources.map(\.rawValue).sorted()
        )))
    }

    fileprivate func excludes(_ root: String) -> Bool {
        if root == "/" || root == "/private/tmp" { return !excludedProjectRoots.isEmpty }
        return excludedProjectRoots.contains { root == $0 || root.hasPrefix($0 + "/") }
    }
}

public enum CollectorPrivacyPolicyError: Error, Equatable, Sendable {
    case invalidPolicy
}

public enum CollectorPrivacyWithheldReason: String, Equatable, Sendable {
    case invalidCapture
    case incompleteMetadata
    case malformedMetadata
    case missingNativeIdentity
    case invalidProjectRoot
    case conflictingProjectRoots
    case conflictingSourceIdentity
    case unsupportedSource
    case excludedProject
    case limitsExceeded
}

public enum CollectorPrivacyAssessment: Equatable, Sendable {
    case eligible(CollectorPrivacyProof)
    case withheld(CollectorPrivacyWithheldReason)
}

public struct CollectorPrivacyProof: Equatable, Sendable {
    public let manifestSHA256: String
    public let wholeSourceSHA256: String
    public let generation: ArchiveSourceGeneration
    public let nativeSessionID: String
    public let source: SourceName
    public let format: SourceMetadataProjection.Format
    /// Nil for rootless CommandCode or Cursor captures under a policy with no project exclusions.
    public let projectRoot: String?
    public let policyRevision: Int64
    public let policySHA256: String
    private let observedProjectRoots: [String]

    public static func assess(
        capture: ArchiveCaptureResult,
        cas: ImmutableArchiveCAS,
        format: SourceMetadataProjection.Format,
        policy: CollectorPrivacyPolicy,
        limits: CollectorPrivacyLimits = .init()
    ) throws -> CollectorPrivacyAssessment {
        try Task.checkCancellation()
        guard captureIsConsistent(capture) else { return .withheld(.invalidCapture) }
        let manifest = capture.manifest
        if format == .vscode {
            return try assessVSCode(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .cline {
            return try assessCline(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .cursor {
            if capture.manifest.replayLayout.cursorLegacySession != nil {
                return try assessCursorLegacy(capture: capture, cas: cas, policy: policy, limits: limits)
            }
            return try assessCursor(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .opencode {
            return try assessOpenCode(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .copilot {
            return try assessCopilot(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .geminiCli {
            return try assessGemini(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .kimi {
            return try assessKimi(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .grok {
            return try assessGrok(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .antigravityCLITranscript {
            return try assessAntigravityCLITranscript(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        if format == .windsurfHookTranscript {
            return try assessWindsurfHookTranscript(capture: capture, cas: cas, policy: policy, limits: limits)
        }
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
        var projection = SourceMetadataProjection(format: format, locator: manifest.locator)
        var pendingLine = Data()
        var recordCount = 0
        var wholeHasher = SHA256()
        var totalBytes: Int64 = 0
        let collectDefaultClaudeRoots = format == .claudeCode(forceClaudeCodeSource: false)
        var observedRawRoots: [String] = []
        var seenRootUTF8 = Set<Data>()
        var totalRootBytes = 0
        var rootLimitsExceeded = false

        func consumeLine(_ line: Data) -> CollectorPrivacyWithheldReason? {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
            guard recordCount < limits.maxRecords else { return .limitsExceeded }
            recordCount += 1
            return autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return .malformedMetadata
                }
                if collectDefaultClaudeRoots, !rootLimitsExceeded,
                   let cwd = SourceMetadataProjection.recognizedClaudeCodeCWD(from: object) {
                    let utf8 = Data(cwd.utf8)
                    if !seenRootUTF8.contains(utf8) {
                        let (remaining, overflow) = limits.maxTotalProjectRootBytes.subtractingReportingOverflow(totalRootBytes)
                        if observedRawRoots.count >= limits.maxProjectRoots || overflow || utf8.count > remaining {
                            rootLimitsExceeded = true
                        } else {
                            seenRootUTF8.insert(utf8)
                            observedRawRoots.append(cwd)
                            totalRootBytes += utf8.count
                        }
                    }
                }
                projection.consume(object)
                return nil
            }
        }

        do {
            let storedManifest = try cas.readManifest(sha256: capture.capture.unboundManifestSHA256)
            guard storedManifest == capture.capture.unboundManifestBytes else { return .withheld(.invalidCapture) }
            for reference in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: reference.rawSHA256)
                guard Int64(bytes.count) == reference.rawByteCount else { return .withheld(.invalidCapture) }
                let sum = totalBytes.addingReportingOverflow(Int64(bytes.count))
                guard !sum.overflow, sum.partialValue <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
                totalBytes = sum.partialValue
                wholeHasher.update(data: bytes)
                var start = bytes.startIndex
                while start < bytes.endIndex {
                    try Task.checkCancellation()
                    let newline = bytes[start...].firstIndex(of: 0x0A)
                    let end = newline ?? bytes.endIndex
                    let count = bytes.distance(from: start, to: end)
                    guard count <= limits.maxLineBytes - pendingLine.count else { return .withheld(.limitsExceeded) }
                    pendingLine.append(contentsOf: bytes[start..<end])
                    guard let newline else { break }
                    if let reason = consumeLine(pendingLine) { return .withheld(reason) }
                    pendingLine.removeAll(keepingCapacity: true)
                    start = bytes.index(after: newline)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .withheld(.invalidCapture)
        }

        try Task.checkCancellation()
        guard totalBytes == manifest.rawByteCount,
              wholeHasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }
        // Indexing can tolerate a final partial line. Upload authorization cannot
        // treat a prefix as complete evidence about the captured generation.
        guard pendingLine.isEmpty, projection.sawRecognizedRecord else { return .withheld(.incompleteMetadata) }
        let allowsMultipleRoots = collectDefaultClaudeRoots && projection.source == .claudeCode
        if rootLimitsExceeded && allowsMultipleRoots {
            return .withheld(.limitsExceeded)
        }
        if projection.hasConflictingRoots, !allowsMultipleRoots {
            return .withheld(.conflictingProjectRoots)
        }
        guard !projection.hasConflictingIdentities, !projection.hasConflictingSources,
              projection.source.rawValue == manifest.source else { return .withheld(.conflictingSourceIdentity) }
        guard !projection.hasInvalidIdentityEvidence,
              let nativeID = projection.nativeSessionID,
              !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nativeID.utf8.contains(0) else { return .withheld(.missingNativeIdentity) }
        guard !projection.hasInvalidRootEvidence else {
            return .withheld(.invalidProjectRoot)
        }
        let projectRoot: String?
        if let cwd = projection.cwd {
            guard let normalized = SourceMetadataProjection.publicationProjectRoot(cwd, format: format),
                  Self.isCanonicalPublicationRoot(normalized) else {
                return .withheld(.invalidProjectRoot)
            }
            projectRoot = normalized
        } else if format == .commandcode, policy.excludedProjectRoots.isEmpty {
            // Current CommandCode logs may omit cwd and use a lossy directory slug.
            // An unrestricted policy permits archiving without inventing a project;
            // any project exclusion requires real root evidence before publication.
            projectRoot = nil
        } else {
            return .withheld(.invalidProjectRoot)
        }
        guard [.claudeCode, .codex, .minimax, .lobsterai, .qwen, .qoder, .iflow, .commandcode, .copilot, .pi].contains(projection.source),
              policy.allowedSources.contains(projection.source) else { return .withheld(.unsupportedSource) }
        let observedProjectRoots: [String]
        if allowsMultipleRoots {
            var roots: [String] = []
            for raw in observedRawRoots {
                guard let root = SourceMetadataProjection.publicationProjectRoot(raw, format: format),
                      URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
                    return .withheld(.invalidProjectRoot)
                }
                roots.append(raw)
            }
            guard !roots.isEmpty else { return .withheld(.invalidProjectRoot) }
            observedProjectRoots = roots
        } else {
            observedProjectRoots = projectRoot.map { [$0] } ?? []
        }
        guard observedProjectRoots.allSatisfy({ !policy.excludes($0) }) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation,
            nativeSessionID: nativeID,
            source: projection.source,
            format: format,
            projectRoot: projectRoot,
            policyRevision: policy.revision,
            policySHA256: try policy.sha256(),
            observedProjectRoots: observedProjectRoots
        ))
    }

    /// The uploader must call this with a freshly read policy and resolved
    /// source format immediately before each request. This checks authorization bindings, not remote ACK or local
    /// object residency; reading each upload object still verifies its CAS hash.
    public func isCurrent(
        for capture: ArchiveCaptureResult,
        policy: CollectorPrivacyPolicy,
        format: SourceMetadataProjection.Format
    ) -> Bool {
        Self.captureIsConsistent(capture)
            && self.format == format
            && manifestSHA256 == capture.capture.unboundManifestSHA256
            && wholeSourceSHA256 == capture.manifest.wholeSourceSHA256
            && generation == capture.manifest.generation
            && source.rawValue == capture.manifest.source
            && policyRevision == policy.revision
            && policySHA256 == (try? policy.sha256())
            && policy.allowedSources.contains(source)
            && (!observedProjectRoots.isEmpty || (projectRoot == nil && policy.excludedProjectRoots.isEmpty
                && (format == .commandcode || format == .cursor)))
            && observedProjectRoots.allSatisfy { root in
                SourceMetadataProjection.publicationProjectRoot(root, format: format) != nil
                    && Self.isCanonicalPublicationRoot(root)
                    && !policy.excludes(root)
            }
    }

    private static func isCanonicalPublicationRoot(_ root: String) -> Bool {
        if root == "/private/tmp" {
            // Verify the physical directory without Foundation's /private alias
            // abbreviation. No component may be a symlink.
            guard let opened = try? CollectorPOSIXDirectoryAccess.openAbsolute(components: ["private", "tmp"]) else {
                return false
            }
            CollectorPOSIXDirectoryAccess.close(opened.descriptor)
            return true
        }
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root
    }

    private static func assessCursorLegacy(
        capture: ArchiveCaptureResult, cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy, limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard ArchiveSourceDescriptor.isCursorLegacySession(manifest),
              let context = manifest.replayLayout.cursorLegacySession else { return .withheld(.invalidCapture) }
        guard policy.allowedSources.contains(.cursor) else { return .withheld(.unsupportedSource) }
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= min(limits.maxSourceBytes, ArchiveCursorLegacySession.maximumEncodedByteCount) else {
            return .withheld(.limitsExceeded)
        }
        let session: ArchiveCursorLegacySession
        do {
            guard try cas.readManifest(sha256: capture.capture.unboundManifestSHA256,
                maximumByteCount: Int64(ArchiveV2ProtocolLimits.maxManifestBytes)) == capture.capture.unboundManifestBytes else {
                return .withheld(.invalidCapture)
            }
            var body = Data()
            for chunk in manifest.chunks {
                try Task.checkCancellation()
                guard chunk.rawByteCount <= manifest.rawByteCount - Int64(body.count) else {
                    return .withheld(.invalidCapture)
                }
                let bytes = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                guard Int64(bytes.count) == chunk.rawByteCount else { return .withheld(.invalidCapture) }
                body.append(bytes)
            }
            guard Int64(body.count) == manifest.rawByteCount,
                  ArchiveV2Hash.sha256(body) == manifest.wholeSourceSHA256 else { return .withheld(.invalidCapture) }
            session = try ArchiveCursorLegacySession.decodeCanonical(body)
            guard session.databaseGeneration == manifest.generation,
                  try ArchiveCursorLegacyContext(session: session) == context else { return .withheld(.invalidCapture) }
        } catch is CancellationError { throw CancellationError() }
        catch { return .withheld(.invalidCapture) }
        try Task.checkCancellation()
        // Ownership is frozen in the captured body. Never rediscover the live
        // shared store or infer a project from conversation text for admission.
        guard session.bubbles.count < limits.maxRecords,
              session.cwd.utf8.count <= limits.maxLineBytes,
              session.cwd.utf8.count <= limits.maxTotalProjectRootBytes else { return .withheld(.limitsExceeded) }
        if session.cwd.isEmpty {
            guard policy.excludedProjectRoots.isEmpty else { return .withheld(.invalidProjectRoot) }
            return .eligible(CollectorPrivacyProof(
                manifestSHA256: capture.capture.unboundManifestSHA256, wholeSourceSHA256: manifest.wholeSourceSHA256,
                generation: manifest.generation, nativeSessionID: session.composerID, source: .cursor, format: .cursor,
                projectRoot: nil, policyRevision: policy.revision, policySHA256: try policy.sha256(),
                observedProjectRoots: []))
        }
        guard let root = SourceMetadataProjection.normalizedProjectRoot(session.cwd),
              URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
            return .withheld(.invalidProjectRoot)
        }
        guard !policy.excludes(root) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256, wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation, nativeSessionID: session.composerID, source: .cursor, format: .cursor,
            projectRoot: root, policyRevision: policy.revision, policySHA256: try policy.sha256(),
            observedProjectRoots: [root]))
    }

    private static func assessCursor(
        capture: ArchiveCaptureResult, cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy, limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard ArchiveSourceDescriptor.isCursorModernFileSet(manifest),
              let nativeID = ArchiveSourceDescriptor.cursorModernSessionID(manifest.replayLayout, locator: manifest.locator),
              let files = manifest.replayLayout.files else { return .withheld(.invalidCapture) }
        guard policy.allowedSources.contains(.cursor) else { return .withheld(.unsupportedSource) }
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
        var aggregate = Data()
        var members: [Data: Data] = [:]
        do {
            guard try cas.readManifest(sha256: capture.capture.unboundManifestSHA256,
                maximumByteCount: Int64(ArchiveV2ProtocolLimits.maxManifestBytes)) == capture.capture.unboundManifestBytes else {
                return .withheld(.invalidCapture)
            }
            for chunk in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                guard Int64(bytes.count) == chunk.rawByteCount,
                      Int64(bytes.count) <= manifest.rawByteCount - Int64(aggregate.count) else {
                    return .withheld(.invalidCapture)
                }
                aggregate.append(bytes)
            }
            guard Int64(aggregate.count) == manifest.rawByteCount,
                  ArchiveV2Hash.sha256(aggregate) == manifest.wholeSourceSHA256 else { return .withheld(.invalidCapture) }
            for file in files {
                try Task.checkCancellation()
                let end = file.byteOffset.addingReportingOverflow(file.rawByteCount)
                guard !end.overflow, file.byteOffset >= 0, end.partialValue <= Int64(aggregate.count) else {
                    return .withheld(.invalidCapture)
                }
                let bytes = aggregate.subdata(in: Int(file.byteOffset)..<Int(end.partialValue))
                guard ArchiveV2Hash.sha256(bytes) == file.wholeSourceSHA256 else { return .withheld(.invalidCapture) }
                members[Data(file.relativePath.utf8)] = bytes
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return .withheld(.invalidCapture) }

        var storedText: String?
        var liveText: String?
        if let store = files.first(where: { $0.relativePath.hasSuffix("/store.db") }) {
            let parent = store.relativePath.split(separator: "/").dropLast().joined(separator: "/")
            if let live = members[Data((parent + "/meta.json").utf8)] {
                guard live.count <= limits.maxLineBytes else { return .withheld(.limitsExceeded) }
                guard let text = String(data: live, encoding: .utf8) else { return .withheld(.malformedMetadata) }
                liveText = text
            }
            guard let main = members[Data(store.relativePath.utf8)] else { return .withheld(.invalidCapture) }
            do {
                storedText = try CollectorCursorSource.readCapturedStoreMetadata(
                    databaseBytes: main, walBytes: members[Data((store.relativePath + "-wal").utf8)],
                    stagingParent: cas.snapshotStagingParent,
                    budget: .init(maximumSourceBytes: limits.maxSourceBytes, maximumMetadataBytes: limits.maxLineBytes))
            } catch is CancellationError { throw CancellationError() }
            catch CollectorSQLiteSnapshotError.exceededBudget { return .withheld(.limitsExceeded) }
            catch { return .withheld(.invalidCapture) }
        }
        let metadataRecords = (storedText == nil ? 0 : 1) + (liveText == nil ? 0 : 1)
        guard metadataRecords <= limits.maxRecords else { return .withheld(.limitsExceeded) }
        let projection = SourceMetadataProjection.cursorModernMetadata(storedText: storedText, liveText: liveText)
        guard !projection.hasMalformedMetadata else { return .withheld(.malformedMetadata) }
        var roots: [String] = []
        var totalRootBytes = 0
        for raw in projection.observedRawCWDs where !raw.isEmpty {
            guard roots.count < limits.maxProjectRoots,
                  raw.utf8.count <= limits.maxTotalProjectRootBytes - totalRootBytes else { return .withheld(.limitsExceeded) }
            totalRootBytes += raw.utf8.count
            guard let root = SourceMetadataProjection.normalizedProjectRoot(raw),
                  URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
                return .withheld(.invalidProjectRoot)
            }
            guard !policy.excludes(root) else { return .withheld(.excludedProject) }
            roots.append(root)
        }
        guard !projection.hasInvalidRootEvidence else { return .withheld(.invalidProjectRoot) }
        if projection.cwd.isEmpty {
            guard roots.isEmpty else { return .withheld(.invalidProjectRoot) }
            guard policy.excludedProjectRoots.isEmpty else { return .withheld(.invalidProjectRoot) }
            return .eligible(CollectorPrivacyProof(
                manifestSHA256: capture.capture.unboundManifestSHA256, wholeSourceSHA256: manifest.wholeSourceSHA256,
                generation: manifest.generation, nativeSessionID: nativeID, source: .cursor, format: .cursor,
                projectRoot: nil, policyRevision: policy.revision, policySHA256: try policy.sha256(),
                observedProjectRoots: []))
        }
        guard let root = SourceMetadataProjection.normalizedProjectRoot(projection.cwd),
              URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
            return .withheld(.invalidProjectRoot)
        }
        // Only default Claude has an explicitly accepted multi-root exception.
        guard roots.count <= 1 else { return .withheld(.conflictingProjectRoots) }
        guard roots.first?.utf8.elementsEqual(root.utf8) == true else { return .withheld(.invalidProjectRoot) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256, wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation, nativeSessionID: nativeID, source: .cursor, format: .cursor,
            projectRoot: root, policyRevision: policy.revision, policySHA256: try policy.sha256(), observedProjectRoots: roots))
    }

    private static func assessOpenCode(
        capture: ArchiveCaptureResult, cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy, limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard ArchiveSourceDescriptor.isOpenCodeSessionImage(manifest),
              let context = manifest.replayLayout.sqliteSession else { return .withheld(.invalidCapture) }
        guard policy.allowedSources.contains(.opencode) else { return .withheld(.unsupportedSource) }
        guard limits.maxSourceBytes > 0, limits.maxRecords > 0, limits.maxLineBytes > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
        var image = Data()
        let metadata: (cwd: String, nativePayloadByteCount: Int64)
        do {
            guard try cas.readManifest(sha256: capture.capture.unboundManifestSHA256) == capture.capture.unboundManifestBytes else {
                return .withheld(.invalidCapture)
            }
            for reference in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: reference.rawSHA256, maximumByteCount: reference.rawByteCount)
                guard Int64(bytes.count) == reference.rawByteCount,
                      Int64(bytes.count) <= manifest.rawByteCount - Int64(image.count) else {
                    return .withheld(.invalidCapture)
                }
                image.append(bytes)
            }
            guard Int64(image.count) == manifest.rawByteCount,
                  ArchiveV2Hash.sha256(image) == manifest.wholeSourceSHA256 else { return .withheld(.invalidCapture) }
            metadata = try CollectorOpenCodeSource.privacyMetadata(image: image,
                nativeSessionID: context.nativeSessionID,
                budget: .init(maximumByteCount: limits.maxSourceBytes, maximumRows: limits.maxRecords))
        } catch is CancellationError { throw CancellationError() }
        catch CollectorOpenCodeSourceError.exceededBudget { return .withheld(.limitsExceeded) }
        catch { return .withheld(.invalidCapture) }
        guard metadata.nativePayloadByteCount == context.nativePayloadByteCount else { return .withheld(.invalidCapture) }
        guard metadata.cwd.utf8.count <= limits.maxLineBytes,
              metadata.cwd.utf8.count <= limits.maxTotalProjectRootBytes else { return .withheld(.limitsExceeded) }
        guard let root = SourceMetadataProjection.publicationProjectRoot(metadata.cwd, format: .opencode),
              Self.isCanonicalPublicationRoot(root) else {
            return .withheld(.invalidProjectRoot)
        }
        guard !policy.excludes(root) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256, wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation, nativeSessionID: context.nativeSessionID, source: .opencode,
            format: .opencode, projectRoot: root, policyRevision: policy.revision,
            policySHA256: try policy.sha256(), observedProjectRoots: [root]
        ))
    }

    private static func assessCopilot(
        capture: ArchiveCaptureResult,
        cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy,
        limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes,
              manifest.schemaVersion == 2, manifest.replayLayout.strategy == .fileSet,
              ArchiveSourceDescriptor.isCopilotFileSet(manifest),
              let files = manifest.replayLayout.files else {
            return .withheld(.invalidCapture)
        }
        var concat = Data()
        concat.reserveCapacity(Int(truncatingIfNeeded: manifest.rawByteCount))
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        do {
            let storedManifest = try cas.readManifest(sha256: capture.capture.unboundManifestSHA256)
            guard storedManifest == capture.capture.unboundManifestBytes else { return .withheld(.invalidCapture) }
            for reference in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: reference.rawSHA256)
                guard Int64(bytes.count) == reference.rawByteCount else { return .withheld(.invalidCapture) }
                let sum = totalBytes.addingReportingOverflow(Int64(bytes.count))
                guard !sum.overflow, sum.partialValue <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
                totalBytes = sum.partialValue
                hasher.update(data: bytes)
                concat.append(bytes)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .withheld(.invalidCapture)
        }
        guard totalBytes == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }

        var yamlID: String?
        var yamlCWD: String?
        var eventRoots: [String] = []
        var sawRecognizedRecord = false
        var recordCount = 0
        for file in files {
            try Task.checkCancellation()
            let start = Int(file.byteOffset)
            let end = start + Int(file.rawByteCount)
            guard start >= 0, end >= start, end <= concat.count else { return .withheld(.invalidCapture) }
            let slice = concat.subdata(in: start..<end)
            guard ArchiveV2Hash.sha256(slice) == file.wholeSourceSHA256,
                  Int64(slice.count) == file.rawByteCount else {
                return .withheld(.invalidCapture)
            }
            if file.relativePath.hasSuffix("/checkpoints/index.md"),
               manifest.replayLayout.entrypointRelativePath?.utf8.elementsEqual(file.relativePath.utf8) == true,
               let content = String(data: slice, encoding: .utf8),
               content.split(separator: "\n", omittingEmptySubsequences: false)
                    .contains(where: CollectorCopilotSource.isIndexRow) {
                sawRecognizedRecord = true
            }
            if file.relativePath == "workspace.yaml" || file.relativePath.hasSuffix("/workspace.yaml") {
                let parsed = CollectorCopilotSource.parseWorkspace(bytes: slice)
                // Present empty `id:` is native failure, not an absent key.
                if let id = parsed["id"] { yamlID = id }
                if let cwd = parsed["cwd"], !cwd.isEmpty { yamlCWD = cwd }
                if yamlID != nil { sawRecognizedRecord = true }
            }
            if file.relativePath == "events.jsonl" || file.relativePath.hasSuffix("/events.jsonl") {
                var startIndex = slice.startIndex
                while startIndex < slice.endIndex {
                    try Task.checkCancellation()
                    let newline = slice[startIndex...].firstIndex(of: 0x0A) ?? slice.endIndex
                    let count = slice.distance(from: startIndex, to: newline)
                    guard count <= limits.maxLineBytes else { return .withheld(.limitsExceeded) }
                    let line = slice[startIndex..<newline]
                    if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                        guard recordCount < limits.maxRecords else { return .withheld(.limitsExceeded) }
                        recordCount += 1
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                            return .withheld(.malformedMetadata)
                        }
                        if let type = object["type"] as? String {
                            if type == "user.message" || type == "assistant.message" {
                                let data = object["data"] as? [String: Any]
                                let content = (data?["content"] as? String) ?? ""
                                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    sawRecognizedRecord = true
                                }
                            }
                            if type == "session.start",
                               let data = object["data"] as? [String: Any],
                               let context = data["context"] as? [String: Any],
                               let cwd = context["cwd"] as? String, !cwd.isEmpty {
                                eventRoots.append(cwd)
                            }
                        }
                    }
                    guard newline < slice.endIndex else { break }
                    startIndex = slice.index(after: newline)
                }
            }
        }

        guard sawRecognizedRecord else { return .withheld(.incompleteMetadata) }
        let directoryID = manifest.replayLayout.entrypointRelativePath
            .flatMap { $0.split(separator: "/").first }
            .map(String.init)
        guard let nativeID = yamlID ?? directoryID,
              !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nativeID.utf8.contains(0) else {
            return .withheld(.missingNativeIdentity)
        }
        var observedRawRoots: [String] = []
        if let yamlCWD { observedRawRoots.append(yamlCWD) }
        observedRawRoots.append(contentsOf: eventRoots)
        var uniqueRoots: [String] = []
        var seen = Set<Data>()
        var totalRootBytes = 0
        for raw in observedRawRoots {
            let utf8 = Data(raw.utf8)
            if seen.contains(utf8) { continue }
            if uniqueRoots.count >= limits.maxProjectRoots
                || totalRootBytes > limits.maxTotalProjectRootBytes - utf8.count {
                return .withheld(.limitsExceeded)
            }
            seen.insert(utf8)
            uniqueRoots.append(raw)
            totalRootBytes += utf8.count
        }
        guard !uniqueRoots.isEmpty else { return .withheld(.invalidProjectRoot) }
        var normalized: [String] = []
        for raw in uniqueRoots {
            guard let projectRoot = SourceMetadataProjection.normalizedProjectRoot(raw),
                  URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path == projectRoot else {
                return .withheld(.invalidProjectRoot)
            }
            normalized.append(projectRoot)
        }
        guard policy.allowedSources.contains(.copilot) else { return .withheld(.unsupportedSource) }
        guard normalized.allSatisfy({ !policy.excludes($0) }) else { return .withheld(.excludedProject) }
        let projectRoot = normalized[0]
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation,
            nativeSessionID: nativeID,
            source: .copilot,
            format: .copilot,
            projectRoot: projectRoot,
            policyRevision: policy.revision,
            policySHA256: try policy.sha256(),
            observedProjectRoots: normalized
        ))
    }

    private static func assessKimi(
        capture: ArchiveCaptureResult, cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy, limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
        guard ArchiveSourceDescriptor.isKimiFileSet(manifest),
              let context = manifest.replayLayout.kimiProjectContext,
              let files = manifest.replayLayout.files else { return .withheld(.invalidCapture) }
        var aggregate = Data()
        var total: Int64 = 0
        var hasher = SHA256()
        do {
            guard try cas.readManifest(sha256: capture.capture.unboundManifestSHA256,
                maximumByteCount: Int64(ArchiveV2ProtocolLimits.maxManifestBytes)) == capture.capture.unboundManifestBytes else {
                return .withheld(.invalidCapture)
            }
            for chunk in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                guard Int64(bytes.count) == chunk.rawByteCount else { return .withheld(.invalidCapture) }
                let next = total.addingReportingOverflow(Int64(bytes.count))
                guard !next.overflow, next.partialValue <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
                total = next.partialValue
                aggregate.append(bytes)
                hasher.update(data: bytes)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return .withheld(.invalidCapture) }
        guard total == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }
        var records = 0
        var conversation = false
        for file in files {
            try Task.checkCancellation()
            let end = file.byteOffset.addingReportingOverflow(file.rawByteCount)
            guard !end.overflow, file.byteOffset >= 0, end.partialValue <= Int64(aggregate.count) else {
                return .withheld(.invalidCapture)
            }
            let bytes = aggregate.subdata(in: Int(file.byteOffset)..<Int(end.partialValue))
            guard ArchiveV2Hash.sha256(bytes) == file.wholeSourceSHA256 else { return .withheld(.invalidCapture) }
            let isWire = file.relativePath.hasSuffix("/wire.jsonl")
            func consume(_ line: Data) -> CollectorPrivacyWithheldReason? {
                if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
                guard records < limits.maxRecords else { return .limitsExceeded }
                records += 1
                // Wire is immutable timing/usage input. Only native context
                // records can supply the conversation witness for eligibility.
                if isWire { return nil }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return .malformedMetadata
                }
                if let role = object["role"] as? String, ["user", "assistant", "tool"].contains(role) {
                    conversation = true
                }
                return nil
            }
            var line = Data()
            for byte in bytes {
                if byte == 0x0A {
                    try Task.checkCancellation()
                    if let failure = consume(line) { return .withheld(failure) }
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < limits.maxLineBytes else { return .withheld(.limitsExceeded) }
                    line.append(byte)
                }
            }
            if !line.isEmpty, let failure = consume(line) { return .withheld(failure) }
        }
        guard conversation else { return .withheld(.incompleteMetadata) }
        guard let root = SourceMetadataProjection.normalizedProjectRoot(context.cwd),
              URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
            return .withheld(.invalidProjectRoot)
        }
        guard root.utf8.count <= limits.maxTotalProjectRootBytes else { return .withheld(.limitsExceeded) }
        guard policy.allowedSources.contains(.kimi) else { return .withheld(.unsupportedSource) }
        guard !policy.excludes(root) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256, wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation, nativeSessionID: context.nativeSessionID, source: .kimi, format: .kimi,
            projectRoot: root, policyRevision: policy.revision, policySHA256: try policy.sha256(),
            observedProjectRoots: [root]))
    }

    private static func assessGemini(
        capture: ArchiveCaptureResult,
        cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy,
        limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes,
              ArchiveSourceDescriptor.isGeminiFileSet(manifest),
              let files = manifest.replayLayout.files,
              let entrypoint = manifest.replayLayout.entrypointRelativePath else {
            return .withheld(.invalidCapture)
        }
        var concat = Data()
        concat.reserveCapacity(Int(truncatingIfNeeded: manifest.rawByteCount))
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        do {
            let storedManifest = try cas.readManifest(sha256: capture.capture.unboundManifestSHA256)
            guard storedManifest == capture.capture.unboundManifestBytes else { return .withheld(.invalidCapture) }
            for reference in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: reference.rawSHA256)
                guard Int64(bytes.count) == reference.rawByteCount else { return .withheld(.invalidCapture) }
                let sum = totalBytes.addingReportingOverflow(Int64(bytes.count))
                guard !sum.overflow, sum.partialValue <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
                totalBytes = sum.partialValue
                hasher.update(data: bytes)
                concat.append(bytes)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .withheld(.invalidCapture)
        }
        guard totalBytes == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }

        var sessionId: String?
        var projectRootText: String?
        var sawRecognizedRecord = false
        for file in files {
            try Task.checkCancellation()
            let start = Int(file.byteOffset)
            let end = start + Int(file.rawByteCount)
            guard start >= 0, end >= start, end <= concat.count else { return .withheld(.invalidCapture) }
            let slice = concat.subdata(in: start..<end)
            guard ArchiveV2Hash.sha256(slice) == file.wholeSourceSHA256,
                  Int64(slice.count) == file.rawByteCount else {
                return .withheld(.invalidCapture)
            }
            if file.relativePath.utf8.elementsEqual(entrypoint.utf8) {
                let jsonl = entrypoint.hasSuffix(".jsonl")
                sessionId = CollectorGeminiSource.sessionId(from: slice, jsonl: jsonl)
                if CollectorGeminiSource.recognizedConversation(
                    slice, jsonl: jsonl, maxLineBytes: limits.maxLineBytes, maxRecords: limits.maxRecords
                ) {
                    sawRecognizedRecord = true
                }
            } else if file.relativePath.hasSuffix("/.project_root"),
                      CollectorGeminiSource.projectRootSuppliesCWD(slice),
                      let text = String(data: slice, encoding: .utf8) {
                projectRootText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard sawRecognizedRecord else { return .withheld(.incompleteMetadata) }
        guard let nativeID = sessionId,
              !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nativeID.utf8.contains(0) else {
            return .withheld(.missingNativeIdentity)
        }
        let project = entrypoint.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init)
        let expectedSidecar = project.map { $0 + "/chats/" + nativeID + ".engram.json" }
        let declared = files.map(\.relativePath) + (manifest.replayLayout.absentRelativePaths ?? [])
        let sidecars = declared.filter {
            let parts = $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return parts.count == 3 && parts[1] == "chats" && parts[2].hasSuffix(".engram.json")
        }
        guard let expectedSidecar, sidecars.count == 1,
              sidecars[0].utf8.elementsEqual(expectedSidecar.utf8) else {
            return .withheld(.invalidCapture)
        }
        let rawCWD: String
        if let projectRootText {
            rawCWD = projectRootText
        } else if let context = manifest.replayLayout.geminiProjectContext {
            rawCWD = context.cwd
        } else {
            return .withheld(.invalidProjectRoot)
        }
        guard let projectRoot = SourceMetadataProjection.publicationProjectRoot(rawCWD, format: .geminiCli),
              URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path == projectRoot else {
            return .withheld(.invalidProjectRoot)
        }
        guard policy.allowedSources.contains(.geminiCli) else { return .withheld(.unsupportedSource) }
        guard !policy.excludes(projectRoot) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation,
            nativeSessionID: nativeID,
            source: .geminiCli,
            format: .geminiCli,
            projectRoot: projectRoot,
            policyRevision: policy.revision,
            policySHA256: try policy.sha256(),
            observedProjectRoots: [projectRoot]
        ))
    }

    private static func assessGrok(
        capture: ArchiveCaptureResult,
        cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy,
        limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes,
              ArchiveSourceDescriptor.isGrokFileSet(manifest),
              let files = manifest.replayLayout.files,
              let entrypoint = manifest.replayLayout.entrypointRelativePath else {
            return .withheld(.invalidCapture)
        }
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return .withheld(.invalidCapture) }
        // Verify every original byte while retaining only the two JSON metadata
        // members. updates.jsonl and compaction archives may be hundreds of MiB.
        var metadata: [String: Data] = [:]
        var memberHashers = files.map { _ in SHA256() }
        var memberByteCounts = files.map { _ in Int64(0) }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        do {
            let storedManifest = try cas.readManifest(sha256: capture.capture.unboundManifestSHA256)
            guard storedManifest == capture.capture.unboundManifestBytes else { return .withheld(.invalidCapture) }
            for reference in manifest.chunks {
                try Task.checkCancellation()
                let failure = try autoreleasepool { () throws -> CollectorPrivacyWithheldReason? in
                    let bytes = try cas.readObject(sha256: reference.rawSHA256, maximumByteCount: reference.rawByteCount)
                    guard Int64(bytes.count) == reference.rawByteCount else { return .invalidCapture }
                    let sum = totalBytes.addingReportingOverflow(Int64(bytes.count))
                    guard !sum.overflow, sum.partialValue <= limits.maxSourceBytes else { return .limitsExceeded }
                    hasher.update(data: bytes)
                    for (index, file) in files.enumerated() {
                        let end = file.byteOffset.addingReportingOverflow(file.rawByteCount)
                        guard file.byteOffset >= 0, !end.overflow, end.partialValue <= manifest.rawByteCount else {
                            return .invalidCapture
                        }
                        let lower = max(totalBytes, file.byteOffset)
                        let upper = min(sum.partialValue, end.partialValue)
                        guard lower < upper else { continue }
                        let slice = bytes.subdata(in: Int(lower - totalBytes)..<Int(upper - totalBytes))
                        memberHashers[index].update(data: slice)
                        memberByteCounts[index] += Int64(slice.count)
                        let name = URL(fileURLWithPath: file.relativePath).lastPathComponent
                        if name == "summary.json" || name == "prompt_context.json" {
                            metadata[name, default: Data()].append(slice)
                        }
                    }
                    totalBytes = sum.partialValue
                    return nil
                }
                if let failure { return .withheld(failure) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .withheld(.invalidCapture)
        }
        guard totalBytes == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }
        var summary: [String: Any]?
        var promptContext: [String: Any]?
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard memberByteCounts[index] == file.rawByteCount,
                  memberHashers[index].finalize().map({ String(format: "%02x", $0) }).joined() == file.wholeSourceSHA256 else {
                return .withheld(.invalidCapture)
            }
            let name = URL(fileURLWithPath: file.relativePath).lastPathComponent
            if name == "summary.json" || name == "prompt_context.json" {
                guard let object = CollectorGrokSource.jsonObject(from: metadata[name] ?? Data()) else {
                    return .withheld(.malformedMetadata)
                }
                if name == "summary.json" { summary = object }
                else { promptContext = object }
            }
        }

        guard let nativeID = CollectorGrokSource.nativeSessionID(fromSummary: summary, sessionDirectory: parts[1]),
              !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nativeID.utf8.contains(0) else {
            return .withheld(.missingNativeIdentity)
        }
        guard let rawCWD = CollectorGrokSource.projectCWD(
            summary: summary, promptContext: promptContext, project: parts[0]
        ) else {
            return .withheld(.invalidProjectRoot)
        }
        guard let projectRoot = SourceMetadataProjection.normalizedProjectRoot(rawCWD),
              URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path == projectRoot else {
            return .withheld(.invalidProjectRoot)
        }
        guard projectRoot.utf8.count <= limits.maxTotalProjectRootBytes else { return .withheld(.limitsExceeded) }
        guard policy.allowedSources.contains(.grok) else { return .withheld(.unsupportedSource) }
        guard !policy.excludes(projectRoot) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation,
            nativeSessionID: nativeID,
            source: .grok,
            format: .grok,
            projectRoot: projectRoot,
            policyRevision: policy.revision,
            policySHA256: try policy.sha256(),
            observedProjectRoots: [projectRoot]
        ))
    }

    private static func assessVSCode(
        capture: ArchiveCaptureResult, cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy, limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard ArchiveSourceDescriptor.isVSCodeFileSet(manifest),
              let context = manifest.replayLayout.vscodeWorkspaceContext,
              let files = manifest.replayLayout.files,
              let primary = manifest.replayLayout.entrypointRelativePath else { return .withheld(.invalidCapture) }
        guard policy.allowedSources.contains(.vscode) else { return .withheld(.unsupportedSource) }
        let externalBytes = Int64(context.configurationData?.count ?? 0)
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              externalBytes <= limits.maxSourceBytes,
              manifest.rawByteCount <= limits.maxSourceBytes - externalBytes else { return .withheld(.limitsExceeded) }
        var projection = SourceMetadataProjection(format: .vscode, locator: manifest.locator)
        var pending = Data()
        var workspace: Data?
        var records = 0
        var total: Int64 = 0
        var hasher = SHA256()
        var verifier = try ArchiveFileSetByteVerifier(layout: manifest.replayLayout)
        func consume(_ bytes: Data) -> CollectorPrivacyWithheldReason? {
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let newline = bytes[start...].firstIndex(of: 0x0A)
                let end = newline ?? bytes.endIndex
                guard bytes.distance(from: start, to: end) <= limits.maxLineBytes - pending.count else { return .limitsExceeded }
                pending.append(contentsOf: bytes[start..<end])
                guard let newline else { break }
                if !pending.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    guard records < limits.maxRecords else { return .limitsExceeded }
                    records += 1
                    let valid = autoreleasepool {
                        guard let object = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] else { return false }
                        projection.consume(object)
                        return true
                    }
                    if !valid { return .malformedMetadata }
                }
                pending.removeAll(keepingCapacity: true)
                start = bytes.index(after: newline)
            }
            return nil
        }
        do {
            guard try cas.readManifest(sha256: capture.capture.unboundManifestSHA256,
                maximumByteCount: Int64(ArchiveV2ProtocolLimits.maxManifestBytes)) == capture.capture.unboundManifestBytes else {
                return .withheld(.invalidCapture)
            }
            for chunk in manifest.chunks {
                try Task.checkCancellation()
                guard chunk.rawByteCount <= manifest.rawByteCount - total else { return .withheld(.invalidCapture) }
                let bytes = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                guard Int64(bytes.count) == chunk.rawByteCount else { return .withheld(.invalidCapture) }
                try verifier.append(bytes)
                hasher.update(data: bytes)
                for file in files {
                    let start = max(total, file.byteOffset)
                    let end = min(total + Int64(bytes.count), file.byteOffset + file.rawByteCount)
                    guard start < end else { continue }
                    let slice = bytes.subdata(in: Int(start - total)..<Int(end - total))
                    if file.relativePath.utf8.elementsEqual(primary.utf8) {
                        if let reason = consume(slice) { return .withheld(reason) }
                    } else {
                        if workspace == nil { workspace = Data() }
                        guard slice.count <= ArchiveVSCodeWorkspaceContext.maximumContextBytes - (workspace?.count ?? 0) else {
                            return .withheld(.limitsExceeded)
                        }
                        workspace?.append(slice)
                    }
                }
                total += Int64(bytes.count)
            }
            try verifier.finish()
        } catch is CancellationError { throw CancellationError() }
        catch { return .withheld(.invalidCapture) }
        guard total == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }
        guard pending.isEmpty else { return .withheld(.incompleteMetadata) }
        guard !projection.hasInvalidIdentityEvidence else { return .withheld(.malformedMetadata) }
        guard projection.sawRecognizedRecord else { return .withheld(.incompleteMetadata) }
        guard let nativeID = projection.nativeSessionID,
              !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nativeID.utf8.contains(0) else { return .withheld(.missingNativeIdentity) }
        let metadata: SourceMetadataProjection.VSCodeWorkspaceMetadata
        do { metadata = try SourceMetadataProjection.vscodeWorkspaceMetadata(workspaceData: workspace, context: context) }
        catch { return .withheld(.invalidCapture) }
        guard !metadata.hasInvalidRootEvidence,
              let projectRoot = SourceMetadataProjection.normalizedProjectRoot(metadata.cwd) else {
            return .withheld(.invalidProjectRoot)
        }
        var roots: [String] = []
        var seen = Set<Data>()
        var rootBytes = 0
        for rawRoot in metadata.observedProjectRoots {
            guard let root = SourceMetadataProjection.normalizedProjectRoot(rawRoot),
                  URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
                return .withheld(.invalidProjectRoot)
            }
            guard seen.insert(Data(root.utf8)).inserted else { continue }
            guard roots.count < limits.maxProjectRoots,
                  root.utf8.count <= limits.maxTotalProjectRootBytes - rootBytes else { return .withheld(.limitsExceeded) }
            rootBytes += root.utf8.count
            roots.append(root)
            guard !policy.excludes(root) else { return .withheld(.excludedProject) }
        }
        return .eligible(CollectorPrivacyProof(manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256, generation: manifest.generation,
            nativeSessionID: nativeID, source: .vscode, format: .vscode, projectRoot: projectRoot,
            policyRevision: policy.revision, policySHA256: try policy.sha256(), observedProjectRoots: roots))
    }

    private static func assessCline(
        capture: ArchiveCaptureResult, cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy, limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard ArchiveSourceDescriptor.isClineFileSet(manifest) else { return .withheld(.invalidCapture) }
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
        guard policy.allowedSources.contains(.cline) else { return .withheld(.unsupportedSource) }
        var reader = SourceMetadataProjection.ClineArrayReader(
            maximumRecordBytes: limits.maxLineBytes, maximumRecords: limits.maxRecords)
        var projection = SourceMetadataProjection(format: .cline, locator: manifest.locator)
        var hasher = SHA256()
        var count: Int64 = 0
        do {
            guard try cas.readManifest(sha256: capture.capture.unboundManifestSHA256) == capture.capture.unboundManifestBytes else {
                return .withheld(.invalidCapture)
            }
            for chunk in manifest.chunks {
                try Task.checkCancellation()
                guard chunk.rawByteCount <= limits.maxSourceBytes - count else { return .withheld(.limitsExceeded) }
                let bytes = try cas.readObject(sha256: chunk.rawSHA256, maximumByteCount: chunk.rawByteCount)
                guard Int64(bytes.count) == chunk.rawByteCount else { return .withheld(.invalidCapture) }
                count += Int64(bytes.count); hasher.update(data: bytes)
                try reader.consume(bytes) { object in
                    projection.consume(object)
                }
            }
            try reader.finish()
        } catch is CancellationError { throw CancellationError() }
        catch SourceMetadataProjection.ClineArrayError.limitsExceeded { return .withheld(.limitsExceeded) }
        catch SourceMetadataProjection.ClineArrayError.malformed { return .withheld(.malformedMetadata) }
        catch { return .withheld(.invalidCapture) }
        guard count == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }
        guard projection.sawRecognizedRecord else { return .withheld(.incompleteMetadata) }
        guard let nativeID = projection.nativeSessionID, !nativeID.isEmpty, !nativeID.utf8.contains(0) else {
            return .withheld(.missingNativeIdentity)
        }
        guard !projection.hasConflictingRoots else { return .withheld(.conflictingProjectRoots) }
        guard !projection.hasInvalidRootEvidence, let cwd = projection.cwd,
              let projectRoot = SourceMetadataProjection.normalizedProjectRoot(cwd),
              URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path == projectRoot else {
            return .withheld(.invalidProjectRoot)
        }
        guard projectRoot.utf8.count <= limits.maxTotalProjectRootBytes else { return .withheld(.limitsExceeded) }
        guard !policy.excludes(projectRoot) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256, generation: manifest.generation,
            nativeSessionID: nativeID, source: .cline, format: .cline, projectRoot: projectRoot,
            policyRevision: policy.revision, policySHA256: try policy.sha256(), observedProjectRoots: [projectRoot]))
    }

    /// Official hook JSONL. Identity is the lexical transcripts stem. There is
    /// no reliable cwd: every decoded absolute path token is exclusion evidence,
    /// and eligibility requires at least one valid observed path.
    private static func assessWindsurfHookTranscript(
        capture: ArchiveCaptureResult,
        cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy,
        limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard ArchiveSourceDescriptor.isWindsurfHookTranscript(manifest),
              let nativeID = ArchiveSourceDescriptor.windsurfHookNativeID(logicalLocator: manifest.locator) else {
            return .withheld(.invalidCapture)
        }
        guard !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .withheld(.missingNativeIdentity)
        }
        guard policy.allowedSources.contains(.windsurf) else { return .withheld(.unsupportedSource) }
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }

        var pendingLine = Data()
        var recordCount = 0
        var roots: [String] = []
        var seen = Set<Data>()
        var rootBytes = 0
        var hasher = SHA256()
        var totalBytes: Int64 = 0

        func observe(_ rawRoot: String) -> CollectorPrivacyWithheldReason? {
            // Bound ancestor resolution before filesystem work, not only storage.
            guard rawRoot.utf8.count <= limits.maxTotalProjectRootBytes,
                  rawRoot.utf8.lazy.filter({ $0 == 47 }).prefix(257).count <= 256 else {
                return .limitsExceeded
            }
            if seen.contains(Data(rawRoot.utf8)) { return nil }
            guard let root = SourceMetadataProjection.normalizedProjectRoot(rawRoot),
                  URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
                return .invalidProjectRoot
            }
            // Foundation may leave an aliased path unchanged when its leaf is
            // missing. Check ancestors too before trusting the lexical evidence.
            var ancestor = URL(fileURLWithPath: root).deletingLastPathComponent()
            while ancestor.path != "/" {
                guard ancestor.resolvingSymlinksInPath().standardizedFileURL.path == ancestor.path else {
                    return .invalidProjectRoot
                }
                ancestor.deleteLastPathComponent()
            }
            guard seen.insert(Data(root.utf8)).inserted else { return nil }
            guard roots.count < limits.maxProjectRoots,
                  root.utf8.count <= limits.maxTotalProjectRootBytes - rootBytes else {
                return .limitsExceeded
            }
            rootBytes += root.utf8.count
            roots.append(root)
            return policy.excludes(root) ? .excludedProject : nil
        }

        func consumeLine(_ line: Data) -> CollectorPrivacyWithheldReason? {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
            guard recordCount < limits.maxRecords else { return .limitsExceeded }
            recordCount += 1
            return autoreleasepool {
                guard let text = String(data: line, encoding: .utf8) else { return .malformedMetadata }
                return antigravityCLIStringPaths(in: text, observe: observe, observeAbsolutePath: observe)
            }
        }

        do {
            let storedManifest = try cas.readManifest(sha256: capture.capture.unboundManifestSHA256)
            guard storedManifest == capture.capture.unboundManifestBytes else { return .withheld(.invalidCapture) }
            for reference in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: reference.rawSHA256)
                guard Int64(bytes.count) == reference.rawByteCount else { return .withheld(.invalidCapture) }
                let sum = totalBytes.addingReportingOverflow(Int64(bytes.count))
                guard !sum.overflow, sum.partialValue <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
                totalBytes = sum.partialValue
                hasher.update(data: bytes)
                var start = bytes.startIndex
                while start < bytes.endIndex {
                    try Task.checkCancellation()
                    let newline = bytes[start...].firstIndex(of: 0x0A)
                    let end = newline ?? bytes.endIndex
                    guard bytes.distance(from: start, to: end) <= limits.maxLineBytes - pendingLine.count else {
                        return .withheld(.limitsExceeded)
                    }
                    pendingLine.append(contentsOf: bytes[start..<end])
                    guard let newline else { break }
                    if let reason = consumeLine(pendingLine) { return .withheld(reason) }
                    pendingLine.removeAll(keepingCapacity: true)
                    start = bytes.index(after: newline)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .withheld(.invalidCapture)
        }

        try Task.checkCancellation()
        guard totalBytes == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }
        if let reason = consumeLine(pendingLine) { return .withheld(reason) }
        guard let projectRoot = roots.first else { return .withheld(.invalidProjectRoot) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation,
            nativeSessionID: nativeID,
            source: .windsurf,
            format: .windsurfHookTranscript,
            projectRoot: projectRoot,
            policyRevision: policy.revision,
            policySHA256: try policy.sha256(),
            observedProjectRoots: roots
        ))
    }

    /// CLI brain transcript. Identity is the relative layout; cwd is a bounded
    /// raw prefix. Exclusion walks newline-delimited raw text in the hash loop.
    private static func assessAntigravityCLITranscript(
        capture: ArchiveCaptureResult,
        cas: ImmutableArchiveCAS,
        policy: CollectorPrivacyPolicy,
        limits: CollectorPrivacyLimits
    ) throws -> CollectorPrivacyAssessment {
        let manifest = capture.manifest
        guard ArchiveSourceDescriptor.isAntigravityCLITranscript(manifest),
              let nativeID = SourceMetadataProjection.antigravityCLINativeID(logicalLocator: manifest.locator) else {
            return .withheld(.invalidCapture)
        }
        guard !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .withheld(.missingNativeIdentity)
        }
        guard policy.allowedSources.contains(.antigravity) else { return .withheld(.unsupportedSource) }
        let prefixLimit = SourceMetadataProjection.antigravityCLIPrefixByteLimit
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              limits.maxProjectRoots > 0, limits.maxTotalProjectRootBytes > 0,
              prefixLimit > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }

        var prefix = Data()
        prefix.reserveCapacity(min(prefixLimit, Int(clamping: manifest.rawByteCount)))
        var pendingLine = Data()
        var recordCount = 0
        var roots: [String] = []
        var seen = Set<Data>()
        var rootBytes = 0
        var hasher = SHA256()
        var totalBytes: Int64 = 0

        func observe(_ rawRoot: String) -> CollectorPrivacyWithheldReason? {
            guard let root = SourceMetadataProjection.normalizedProjectRoot(rawRoot),
                  URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == root else {
                return .invalidProjectRoot
            }
            guard seen.insert(Data(root.utf8)).inserted else { return nil }
            guard roots.count < limits.maxProjectRoots,
                  root.utf8.count <= limits.maxTotalProjectRootBytes - rootBytes else {
                return .limitsExceeded
            }
            rootBytes += root.utf8.count
            roots.append(root)
            return policy.excludes(root) ? .excludedProject : nil
        }

        func consumeLine(_ line: Data) -> CollectorPrivacyWithheldReason? {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
            guard recordCount < limits.maxRecords else { return .limitsExceeded }
            recordCount += 1
            return autoreleasepool {
                guard let text = String(data: line, encoding: .utf8) else { return .malformedMetadata }
                return antigravityCLIStringPaths(in: text, observe: observe)
            }
        }

        do {
            let storedManifest = try cas.readManifest(sha256: capture.capture.unboundManifestSHA256)
            guard storedManifest == capture.capture.unboundManifestBytes else { return .withheld(.invalidCapture) }
            for reference in manifest.chunks {
                try Task.checkCancellation()
                let bytes = try cas.readObject(sha256: reference.rawSHA256)
                guard Int64(bytes.count) == reference.rawByteCount else { return .withheld(.invalidCapture) }
                let sum = totalBytes.addingReportingOverflow(Int64(bytes.count))
                guard !sum.overflow, sum.partialValue <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
                totalBytes = sum.partialValue
                hasher.update(data: bytes)
                if prefix.count < prefixLimit {
                    let need = prefixLimit - prefix.count
                    if bytes.count <= need {
                        prefix.append(bytes)
                    } else {
                        prefix.append(bytes.prefix(need))
                    }
                }
                var start = bytes.startIndex
                while start < bytes.endIndex {
                    try Task.checkCancellation()
                    let newline = bytes[start...].firstIndex(of: 0x0A)
                    let end = newline ?? bytes.endIndex
                    guard bytes.distance(from: start, to: end) <= limits.maxLineBytes - pendingLine.count else {
                        return .withheld(.limitsExceeded)
                    }
                    pendingLine.append(contentsOf: bytes[start..<end])
                    guard let newline else { break }
                    if let reason = consumeLine(pendingLine) { return .withheld(reason) }
                    pendingLine.removeAll(keepingCapacity: true)
                    start = bytes.index(after: newline)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .withheld(.invalidCapture)
        }

        try Task.checkCancellation()
        guard totalBytes == manifest.rawByteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.wholeSourceSHA256 else {
            return .withheld(.invalidCapture)
        }
        if let reason = consumeLine(pendingLine) { return .withheld(reason) }
        guard let metadata = SourceMetadataProjection.antigravityCLIPrefixMetadata(
            prefix, hasMoreBytes: totalBytes > Int64(prefix.count)
        ) else {
            return .withheld(.malformedMetadata)
        }
        guard !metadata.cwd.isEmpty,
              let projectRoot = SourceMetadataProjection.normalizedProjectRoot(metadata.cwd),
              URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path == projectRoot else {
            return .withheld(.invalidProjectRoot)
        }
        if let reason = observe(metadata.cwd) { return .withheld(reason) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation,
            nativeSessionID: nativeID,
            source: .antigravity,
            format: .antigravityCLITranscript,
            projectRoot: projectRoot,
            policyRevision: policy.revision,
            policySHA256: try policy.sha256(),
            observedProjectRoots: roots
        ))
    }

    /// Inspect JSON string escapes without materializing an object or message.
    /// The caller bounds each UTF-8 line; at most one decoded string is retained.
    /// `observeAbsolutePath` is Windsurf-only complete-token evidence; Antigravity
    /// omits it and keeps parent-directory regex semantics.
    private static func antigravityCLIStringPaths(
        in text: String,
        observe: (String) -> CollectorPrivacyWithheldReason?,
        observeAbsolutePath: ((String) -> CollectorPrivacyWithheldReason?)? = nil
    ) -> CollectorPrivacyWithheldReason? {
        let bytes = Array(text.utf8)
        var index = 0
        var unquotedStart = 0
        func observeText(_ text: String) -> CollectorPrivacyWithheldReason? {
            if let observeAbsolutePath {
                return observeCompleteAbsolutePaths(in: text, observe: observeAbsolutePath)
            }
            for root in SourceMetadataProjection.antigravityCLIPathMetadata(in: text).observedProjectRoots {
                if let reason = observe(root) { return reason }
            }
            return nil
        }
        func hexUnit() -> UInt32? {
            guard index <= bytes.count - 4 else { return nil }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let digit: UInt32
                switch bytes[index] {
                case 48...57: digit = UInt32(bytes[index] - 48)
                case 65...70: digit = UInt32(bytes[index] - 55)
                case 97...102: digit = UInt32(bytes[index] - 87)
                default: return nil
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }
        while index < bytes.count {
            guard bytes[index] == 34 else { index += 1; continue }
            if let reason = observeText(String(decoding: bytes[unquotedStart..<index], as: UTF8.self)) { return reason }
            index += 1
            var decoded = Data()
            var closed = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 { closed = true; break }
                guard byte >= 32 else { return .malformedMetadata }
                guard byte == 92 else { decoded.append(byte); continue }
                guard index < bytes.count else { return .malformedMetadata }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 34, 47, 92: decoded.append(escape)
                case 98: decoded.append(8)
                case 102: decoded.append(12)
                case 110: decoded.append(10)
                case 114: decoded.append(13)
                case 116: decoded.append(9)
                case 117:
                    guard var value = hexUnit() else { return .malformedMetadata }
                    if (0xD800...0xDBFF).contains(value) {
                        guard index <= bytes.count - 2, bytes[index] == 92, bytes[index + 1] == 117 else {
                            return .malformedMetadata
                        }
                        index += 2
                        guard let low = hexUnit(), (0xDC00...0xDFFF).contains(low) else { return .malformedMetadata }
                        value = 0x10000 + (value - 0xD800) * 0x400 + low - 0xDC00
                    }
                    guard let scalar = UnicodeScalar(value) else { return .malformedMetadata }
                    decoded.append(contentsOf: String(scalar).utf8)
                default: return .malformedMetadata
                }
            }
            guard closed, let string = String(data: decoded, encoding: .utf8) else { return .malformedMetadata }
            if let reason = observeText(string) { return reason }
            unquotedStart = index
        }
        return observeText(String(decoding: bytes[unquotedStart..<index], as: UTF8.self))
    }

    /// Whole decoded token when it is already an absolute path. Does not strip
    /// a filename or invent a parent directory for exclusion.
    private static func observeCompleteAbsolutePaths(
        in text: String, observe: (String) -> CollectorPrivacyWithheldReason?
    ) -> CollectorPrivacyWithheldReason? {
        // File URIs are local path evidence, unlike ordinary web URLs. Decode
        // their percent escapes before checking exclusions, including in prose.
        func observeFileURI(_ candidate: String) -> CollectorPrivacyWithheldReason? {
            guard let url = URL(string: candidate), url.isFileURL,
                  url.user == nil, url.password == nil,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
                return .invalidProjectRoot
            }
            return observe(url.path)
        }
        var uriStart = text.startIndex
        while let match = text.range(of: "file://", options: .caseInsensitive, range: uriStart..<text.endIndex) {
            let end = text[match.lowerBound...].firstIndex(where: { "\n\r\"'`".contains($0) }) ?? text.endIndex
            if let reason = observeFileURI(String(text[match.lowerBound..<end])) { return reason }
            for split in text[match.lowerBound..<end].indices where text[split].isWhitespace {
                if let reason = observeFileURI(String(text[match.lowerBound..<split])) { return reason }
            }
            uriStart = match.upperBound
        }
        var start = text.startIndex
        while start < text.endIndex {
            guard let slash = text[start...].firstIndex(of: "/") else { break }
            let previous = slash == text.startIndex ? nil : text[text.index(before: slash)]
            let next = text.index(after: slash)
            let schemeSeparator = previous == ":" && next < text.endIndex && text[next] == "/"
            let boundary = !schemeSeparator && (previous == nil || previous!.isWhitespace || "\"'`([{=,:;<".contains(previous!))
            if boundary {
                let end = text[slash...].firstIndex(where: { "\n\r\"'`".contains($0) }) ?? text.endIndex
                // Preserve the full candidate first for paths containing spaces.
                // Also inspect whitespace-delimited prefixes and later paths in prose.
                if let reason = observe(String(text[slash..<end])) { return reason }
                for split in text[slash..<end].indices {
                    let next = text.index(after: split)
                    let sentencePeriod = text[split] == "." && (next == end
                        || text[next].isWhitespace || ",;)]}>".contains(text[next]))
                    if text[split].isWhitespace || ",;)]}>".contains(text[split]) || sentencePeriod {
                        if let reason = observe(String(text[slash..<split])) { return reason }
                    }
                }
            }
            start = text.index(after: slash)
        }
        return nil
    }

    private static func captureIsConsistent(_ result: ArchiveCaptureResult) -> Bool {
        let capture = result.capture
        let manifest = result.manifest
        return manifest.sessionID == nil
            && capture.unboundManifestBytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes
            && ArchiveV2Hash.sha256(capture.unboundManifestBytes) == capture.unboundManifestSHA256
            && (try? ArchiveCanonicalJSON.encode(manifest)) == capture.unboundManifestBytes
            && capture.captureID == manifest.captureID
            && capture.machineID == manifest.machineID
            && capture.source == manifest.source
            && capture.locator == manifest.locator
            && capture.generation == manifest.generation
            && capture.wholeSourceSHA256 == manifest.wholeSourceSHA256
            && capture.rawByteCount == manifest.rawByteCount
            && capture.chunkSize == manifest.chunkSize
    }
}

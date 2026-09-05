import CryptoKit
import Foundation

public struct CollectorPrivacyLimits: Equatable, Sendable {
    public let maxSourceBytes: Int64
    public let maxLineBytes: Int
    public let maxRecords: Int

    public init(maxSourceBytes: Int64 = 256 * 1024 * 1024, maxLineBytes: Int = 1024 * 1024, maxRecords: Int = 1_000_000) {
        self.maxSourceBytes = maxSourceBytes
        self.maxLineBytes = maxLineBytes
        self.maxRecords = maxRecords
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
        excludedProjectRoots.contains { root == $0 || root.hasPrefix($0 + "/") }
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
    public let projectRoot: String
    public let policyRevision: Int64
    public let policySHA256: String

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
        guard limits.maxSourceBytes > 0, limits.maxLineBytes > 0, limits.maxRecords > 0,
              manifest.rawByteCount <= limits.maxSourceBytes else { return .withheld(.limitsExceeded) }
        var projection = SourceMetadataProjection(format: format, locator: manifest.locator)
        var pendingLine = Data()
        var recordCount = 0
        var wholeHasher = SHA256()
        var totalBytes: Int64 = 0

        func consumeLine(_ line: Data) -> CollectorPrivacyWithheldReason? {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
            guard recordCount < limits.maxRecords else { return .limitsExceeded }
            recordCount += 1
            return autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return .malformedMetadata
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
        if projection.hasConflictingRoots { return .withheld(.conflictingProjectRoots) }
        guard !projection.hasConflictingIdentities, !projection.hasConflictingSources,
              projection.source.rawValue == manifest.source else { return .withheld(.conflictingSourceIdentity) }
        guard !projection.hasInvalidIdentityEvidence,
              let nativeID = projection.nativeSessionID,
              !nativeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nativeID.utf8.contains(0) else { return .withheld(.missingNativeIdentity) }
        guard !projection.hasInvalidRootEvidence,
              let cwd = projection.cwd,
              let projectRoot = SourceMetadataProjection.normalizedProjectRoot(cwd),
              URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path == projectRoot else {
            return .withheld(.invalidProjectRoot)
        }
        guard [.claudeCode, .codex, .minimax, .lobsterai].contains(projection.source),
              policy.allowedSources.contains(projection.source) else { return .withheld(.unsupportedSource) }
        guard !policy.excludes(projectRoot) else { return .withheld(.excludedProject) }
        return .eligible(CollectorPrivacyProof(
            manifestSHA256: capture.capture.unboundManifestSHA256,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            generation: manifest.generation,
            nativeSessionID: nativeID,
            source: projection.source,
            format: format,
            projectRoot: projectRoot,
            policyRevision: policy.revision,
            policySHA256: try policy.sha256()
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
            && SourceMetadataProjection.normalizedProjectRoot(projectRoot) != nil
            && URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path == projectRoot
            && !policy.excludes(projectRoot)
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

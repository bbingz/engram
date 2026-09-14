import Foundation

struct CollectorRootConfiguration: Equatable {
    let rootID: String
    let source: SourceName
    let rootPath: String
    let revision: Int64
    let cursorLegacy: Bool
    let cursorModernRootID: String?

    init(rootID: String, source: SourceName, rootPath: String, revision: Int64,
         cursorLegacy: Bool = false, cursorModernRootID: String? = nil) {
        self.rootID = rootID
        self.source = source
        self.rootPath = rootPath
        self.revision = revision
        self.cursorLegacy = cursorLegacy
        self.cursorModernRootID = cursorModernRootID
    }

    var validCursorLayout: Bool {
        guard cursorLegacy || cursorModernRootID != nil else { return true }
        guard source == .cursor, cursorLegacy,
              URL(fileURLWithPath: rootPath).lastPathComponent == "globalStorage" else { return false }
        return cursorModernRootID.map {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
                && !$0.utf8.elementsEqual(rootID.utf8)
        } ?? true
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootID.utf8.elementsEqual(rhs.rootID.utf8)
            && lhs.rootPath.utf8.elementsEqual(rhs.rootPath.utf8)
            && lhs.source == rhs.source && lhs.revision == rhs.revision
            && lhs.cursorLegacy == rhs.cursorLegacy
            && lhs.cursorModernRootID.map { Data($0.utf8) } == rhs.cursorModernRootID.map { Data($0.utf8) }
    }
}

// This is an observation, not a stable capture or a privacy proof.
struct CollectorObservedFile: Equatable {
    let relativePath: String
    let observedGeneration: String
}

struct CollectorEventCheckpoint: Equatable {
    let epoch: String
    let cursor: String
}

struct CollectorScanToken: Equatable {
    let rootID: String
    let rootRevision: Int64
    let scanID: String
    let requestedRevision: Int64
}

struct CollectorRootState: Equatable {
    let configuration: CollectorRootConfiguration
    let requestedRevision: Int64
    let completedRevision: Int64
    let eventCheckpoint: CollectorEventCheckpoint?
    let activeScan: CollectorScanToken?
    let lastScanFailure: CollectorBootstrapFailure?
}

struct CollectorLocatorState: Equatable {
    let relativePath: String
    let observedGeneration: String?
    let dirtyRevision: Int64
    let acknowledgedRevision: Int64
    let lastCaptureID: String?
    let retryNotBefore: Int64?
    let lastError: String?
}

struct CollectorDirtyClaim: Equatable {
    let rootID: String
    let rootRevision: Int64
    let relativePath: String
    let dirtyRevision: Int64
    let ownerRunID: String
    let claimGeneration: Int64
    let lastCaptureID: String?

    init(
        rootID: String, rootRevision: Int64, relativePath: String, dirtyRevision: Int64,
        ownerRunID: String, claimGeneration: Int64, lastCaptureID: String? = nil
    ) {
        self.rootID = rootID
        self.rootRevision = rootRevision
        self.relativePath = relativePath
        self.dirtyRevision = dirtyRevision
        self.ownerRunID = ownerRunID
        self.claimGeneration = claimGeneration
        self.lastCaptureID = lastCaptureID
    }
}

enum CollectorClaimCompletion: Equatable {
    case acknowledged
    case newerWorkPending
    case stale
}

struct CollectorBootstrapBatch {
    let scan: CollectorScanToken
    let relativeDirectory: String
    let files: [CollectorObservedFile]
    let childDirectories: [String]
    let directoryFinished: Bool
}

enum CollectorInventoryError: Error, Equatable {
    case invalidRoot
    case unknownRoot
    case invalidRelativePath
    case invalidBudget
    case staleScan
    case staleCheckpoint
    case machineIDMismatch
    case staleOwner
    case invalidState
    case revisionExhausted
}

enum CollectorDirectoryEntry: Equatable {
    case file(CollectorObservedFile)
    case directory(String)
    case ignored(String)
    case symlink(String)
}

struct CollectorBootstrapBudget {
    let maxEntriesVisited: Int
    let maxCandidateFiles: Int
    let maxDirectoryOpens: Int
    // UTF-8 payload bytes of relative paths and observation fingerprints only.
    // This is not SQLite disk usage, raw capture bytes, or upload bytes.
    let maxMetadataBytes: Int
}

enum CollectorBootstrapFailure: Equatable {
    case enumerationUnavailable
    case unsafeEntry
}

enum CollectorBootstrapPauseReason: Equatable {
    case budget
    case diskPressure
}

enum CollectorBootstrapOutcome: Equatable {
    case progress
    case finished
    case paused(CollectorBootstrapPauseReason)
    case blocked(CollectorBootstrapFailure)
}

struct CollectorBootstrapStepResult: Equatable {
    let outcome: CollectorBootstrapOutcome
    let entriesVisited: Int
    let candidateFiles: Int
    let directoriesOpened: Int
    let metadataBytes: Int
}

struct CollectorDependencySnapshot: Equatable, Sendable {
    struct PresentMember: Equatable, Sendable {
        let relativePath: String
        let generation: ArchiveSourceGeneration
    }

    let entrypointRelativePath: String
    let present: [PresentMember]
    let absentRelativePaths: [String]
    let vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext?
    let geminiProjectContext: ArchiveGeminiProjectContext?
    let kimiProjectContext: ArchiveKimiProjectContext?

    init(
        entrypointRelativePath: String,
        present: [PresentMember],
        absentRelativePaths: [String],
        vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext? = nil,
        geminiProjectContext: ArchiveGeminiProjectContext? = nil,
        kimiProjectContext: ArchiveKimiProjectContext? = nil
    ) {
        self.entrypointRelativePath = entrypointRelativePath
        self.present = present
        self.absentRelativePaths = absentRelativePaths
        self.vscodeWorkspaceContext = vscodeWorkspaceContext
        self.geminiProjectContext = geminiProjectContext
        self.kimiProjectContext = kimiProjectContext
    }

    func presentByteCount() throws -> Int64 {
        var total: Int64 = 0
        for member in present {
            let next = total.addingReportingOverflow(member.generation.size)
            guard !next.overflow, member.generation.size >= 0 else {
                throw CollectorPublicationWorkerError.invalidCapture
            }
            total = next.partialValue
        }
        // Frozen external configuration lives in the manifest, outside file-set members,
        // but still consumes the collector capture allowance.
        let contextBytes = Int64(vscodeWorkspaceContext?.configurationData?.count ?? 0)
        let next = total.addingReportingOverflow(contextBytes)
        guard !next.overflow else { throw CollectorPublicationWorkerError.invalidCapture }
        return next.partialValue
    }
}

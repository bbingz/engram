import Foundation

struct CollectorRootConfiguration: Equatable {
    let rootID: String
    let source: SourceName
    let rootPath: String
    let revision: Int64

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootID.utf8.elementsEqual(rhs.rootID.utf8)
            && lhs.rootPath.utf8.elementsEqual(rhs.rootPath.utf8)
            && lhs.source == rhs.source && lhs.revision == rhs.revision
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

import Foundation

// A cursor is process-local. Persisted frontiers name unfinished directories;
// reopening a walker must replay those directories instead of restoring offsets.
protocol CollectorDirectoryCursor: AnyObject {
    func next() throws -> CollectorDirectoryEntry?
}

protocol CollectorRootEnumerator: AnyObject {
    func open(
        configuration: CollectorRootConfiguration,
        relativeDirectory: String
    ) throws -> any CollectorDirectoryCursor
}

// There is deliberately no filesystem or FSEvents adapter.
final class CollectorBootstrapWalker {
    private let store: CollectorInventoryStore
    private let enumerator: any CollectorRootEnumerator
    private var activeScan: CollectorScanToken?
    private var relativeDirectory: String?
    private var cursor: (any CollectorDirectoryCursor)?
    private var pendingEntry: CollectorDirectoryEntry?

    init(store: CollectorInventoryStore, enumerator: any CollectorRootEnumerator) {
        self.store = store
        self.enumerator = enumerator
    }

    func step(
        scan: CollectorScanToken,
        budget: CollectorBootstrapBudget,
        storageAvailable: Bool = true
    ) throws -> CollectorBootstrapStepResult {
        try Task.checkCancellation()
        guard budget.maxEntriesVisited >= 0, budget.maxCandidateFiles >= 0,
              budget.maxDirectoryOpens >= 0, budget.maxMetadataBytes >= 0 else {
            throw CollectorInventoryError.invalidBudget
        }
        var entriesVisited = 0
        var candidateFiles = 0
        var directoriesOpened = 0
        var metadataBytes = 0
        func result(_ outcome: CollectorBootstrapOutcome) -> CollectorBootstrapStepResult {
            CollectorBootstrapStepResult(
                outcome: outcome, entriesVisited: entriesVisited, candidateFiles: candidateFiles,
                directoriesOpened: directoriesOpened, metadataBytes: metadataBytes
            )
        }
        guard storageAvailable else { return result(.paused(.diskPressure)) }
        guard budget.maxEntriesVisited > 0, budget.maxCandidateFiles > 0,
              budget.maxDirectoryOpens > 0, budget.maxMetadataBytes > 0 else { return result(.paused(.budget)) }
        guard let root = try store.rootState(rootID: scan.rootID), root.activeScan == scan else {
            resetCursor()
            throw CollectorInventoryError.staleScan
        }
        if activeScan != scan {
            resetCursor()
            activeScan = scan
        }

        do {
            while true {
                try Task.checkCancellation()
                if cursor == nil {
                    guard let directory = try store.pendingDirectories(scan: scan, limit: 1).first else {
                        guard try store.finishBootstrap(scan) else { throw CollectorInventoryError.staleScan }
                        resetCursor()
                        return result(.finished)
                    }
                    guard entriesVisited < budget.maxEntriesVisited, candidateFiles < budget.maxCandidateFiles,
                          metadataBytes < budget.maxMetadataBytes else { return result(.paused(.budget)) }
                    guard directoriesOpened < budget.maxDirectoryOpens else { return result(.paused(.budget)) }
                    directoriesOpened += 1
                    do {
                        cursor = try enumerator.open(configuration: root.configuration, relativeDirectory: directory)
                        relativeDirectory = directory
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try store.recordScanFailure(scan, failure: .enumerationUnavailable)
                        resetCursor()
                        return result(.blocked(.enumerationUnavailable))
                    }
                }
                guard let cursor, let directory = relativeDirectory else { throw CollectorInventoryError.invalidState }
                var files: [CollectorObservedFile] = []
                var childDirectories: [String] = []
                var directoryFinished = false

                while entriesVisited < budget.maxEntriesVisited,
                      candidateFiles < budget.maxCandidateFiles,
                      metadataBytes < budget.maxMetadataBytes {
                    try Task.checkCancellation()
                    let entry: CollectorDirectoryEntry
                    if let pendingEntry {
                        entry = pendingEntry
                    } else {
                        do {
                            let next = try cursor.next()
                            try Task.checkCancellation()
                            guard let next else {
                                directoryFinished = true
                                break
                            }
                            entriesVisited += 1
                            entry = next
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try store.recordScanFailure(scan, failure: .enumerationUnavailable)
                            resetCursor()
                            return result(.blocked(.enumerationUnavailable))
                        }
                    }

                    let path: String
                    let generation: String?
                    switch entry {
                    case .file(let file): path = file.relativePath; generation = file.observedGeneration
                    case .directory(let value), .ignored(let value), .symlink(let value): path = value; generation = nil
                    }
                    guard CollectorInventoryStore.isDirectChild(path, of: directory), generation?.isEmpty != true else {
                        try store.recordScanFailure(scan, failure: .unsafeEntry)
                        resetCursor()
                        return result(.blocked(.unsafeEntry))
                    }
                    switch entry {
                    case .ignored, .symlink:
                        pendingEntry = nil
                        continue
                    case .file, .directory:
                        break
                    }
                    let (cost, overflow) = path.utf8.count.addingReportingOverflow(generation?.utf8.count ?? 0)
                    guard !overflow else { throw CollectorInventoryError.invalidBudget }
                    guard cost <= budget.maxMetadataBytes - metadataBytes else {
                        // The iterator already visited this entry. Keep it in
                        // memory; after a crash the unfinished directory replays.
                        pendingEntry = entry
                        break
                    }
                    metadataBytes += cost
                    pendingEntry = nil
                    switch entry {
                    case .file(let file): files.append(file); candidateFiles += 1
                    case .directory(let path): childDirectories.append(path)
                    case .ignored, .symlink: break
                    }
                }

                if !files.isEmpty || !childDirectories.isEmpty || directoryFinished {
                    try Task.checkCancellation()
                    try store.applyBootstrapBatch(CollectorBootstrapBatch(
                        scan: scan, relativeDirectory: directory, files: files,
                        childDirectories: childDirectories, directoryFinished: directoryFinished
                    ))
                }
                if directoryFinished {
                    self.cursor = nil
                    relativeDirectory = nil
                    pendingEntry = nil
                } else {
                    return result(.paused(.budget))
                }
            }
        } catch {
            // A failed transaction cannot leave a process-local iterator ahead
            // of its durable frontier. Retry from this directory's head.
            resetCursor()
            throw error
        }
    }

    private func resetCursor() {
        activeScan = nil
        relativeDirectory = nil
        cursor = nil
        pendingEntry = nil
    }
}

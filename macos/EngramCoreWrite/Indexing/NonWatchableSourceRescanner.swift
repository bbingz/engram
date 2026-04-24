import EngramCoreRead

public protocol NonWatchableIndexing: AnyObject {
    func indexAll(sources: Set<SourceName>) async throws -> Int
}

public protocol NonWatchableIndexJobRunning: AnyObject {
    func runRecoverableJobs() async
}

public final class NonWatchableSourceRescanner {
    public static let defaultIntervalMilliseconds = 10 * 60 * 1_000

    private let sources: Set<SourceName>
    private let indexer: any NonWatchableIndexing
    private let indexJobRunner: any NonWatchableIndexJobRunning
    private let totalCount: () throws -> Int
    private let todayParentCount: () throws -> Int

    public init(
        allSources: Set<SourceName>,
        indexer: any NonWatchableIndexing,
        indexJobRunner: any NonWatchableIndexJobRunning,
        totalCount: @escaping () throws -> Int,
        todayParentCount: @escaping () throws -> Int
    ) {
        self.sources = WatchPathRules.nonWatchableSources(from: allSources)
        self.indexer = indexer
        self.indexJobRunner = indexJobRunner
        self.totalCount = totalCount
        self.todayParentCount = todayParentCount
    }

    public func rescanNow() async throws -> [StartupBackfillEvent] {
        guard !sources.isEmpty else { return [] }
        let indexed = try await indexer.indexAll(sources: sources)
        guard indexed > 0 else { return [] }
        await indexJobRunner.runRecoverableJobs()
        return [
            StartupBackfillEvent(
                event: "rescan",
                payload: [
                    "indexed": .int(indexed),
                    "total": .int(try totalCount()),
                    "todayParents": .int(try todayParentCount())
                ]
            )
        ]
    }
}

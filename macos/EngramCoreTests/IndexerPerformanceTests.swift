import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class IndexerPerformanceTests: XCTestCase {
    private static let expectedFixtureCount = 20

    func testSwiftIndexerThroughputForGeneratedSessionFixtures() throws {
        guard ProcessInfo.processInfo.environment["ENGRAM_PERF"] == "1" else {
            throw XCTSkip("perf run disabled")
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        let workload = try Self.fixtureWorkload()
        XCTAssertEqual(workload.fixtureCount, Self.expectedFixtureCount)

        measure(metrics: [XCTClockMetric()], options: options) {
            do {
                let indexed = try Self.waitForAsyncOperation(timeout: .seconds(120)) {
                    try await Self.indexGeneratedSessionFixturesOnce()
                }
                XCTAssertEqual(indexed, workload.fixtureCount)
                print(
                    "ENGRAM_PERF_WORKLOAD fixtures=\(workload.fixtureCount) "
                        + "bytes=\(workload.fixtureBytes) indexed=\(indexed)"
                )
            } catch {
                XCTFail("Swift indexer perf run failed: \(error)")
            }
        }
    }

    private static func fixtureWorkload() throws -> (fixtureCount: Int, fixtureBytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionFixtureRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PerformanceTestError.missingFixture(sessionFixtureRoot.path)
        }

        var fixtureCount = 0
        var fixtureBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard ["json", "jsonl"].contains(url.pathExtension) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            fixtureCount += 1
            fixtureBytes += Int64(values.fileSize ?? 0)
        }
        return (fixtureCount, fixtureBytes)
    }

    private static func indexGeneratedSessionFixturesOnce() async throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionFixtureRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PerformanceTestError.missingFixture(sessionFixtureRoot.path)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-indexer-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("index.sqlite").path)
        try writer.migrate()

        let indexer = SwiftIndexer(
            sink: PerformanceIndexingSink(writer: writer),
            adapters: [GeneratedFixtureSessionAdapter(root: sessionFixtureRoot)],
            authoritativeNode: "perf-fixture-node"
        )
        return try await indexer.indexAll(sources: [.codex])
    }

    private static var sessionFixtureRoot: URL {
        repoRoot.appendingPathComponent("test-fixtures/sessions/generated")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func waitForAsyncOperation<T: Sendable>(
        timeout: DispatchTimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResult<T>()

        Task {
            do {
                result.store(.success(try await operation()))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw PerformanceTestError.timedOut
        }
        guard let value = result.value() else {
            throw PerformanceTestError.missingResult
        }
        return try value.get()
    }
}

private final class GeneratedFixtureSessionAdapter: SessionAdapter {
    let source: SourceName = .codex
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func detect() async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func listSessionLocators() async throws -> [String] {
        try collectSessionLocators()
    }

    private func collectSessionLocators() throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var locators: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard ["json", "jsonl"].contains(url.pathExtension) else { continue }
            locators.append(url.path)
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        switch try await scanForIndexing(locator: locator) {
        case .success(let scan):
            return .success(scan.info)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        let messages: [NormalizedMessage]
        switch try await scanForIndexing(locator: locator) {
        case .success(let scan):
            let offset = options.offset ?? 0
            let limit = options.limit ?? scan.messages.count
            messages = Array(scan.messages.dropFirst(offset).prefix(limit))
        case .failure(let failure):
            throw failure
        }

        return AsyncThrowingStream { continuation in
            for message in messages {
                continuation.yield(message)
            }
            continuation.finish()
        }
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        let url = URL(fileURLWithPath: locator)
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.fileMissing)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return .failure(.invalidUtf8)
        }

        let startTime = "2026-01-01T00:00:00Z"
        let visibleContent = content
            .split(whereSeparator: \.isNewline)
            .prefix(5)
            .joined(separator: "\n")
        let messageContent = visibleContent.isEmpty ? url.lastPathComponent : String(visibleContent)
        let message = NormalizedMessage(
            role: .user,
            content: messageContent,
            timestamp: startTime
        )
        let info = NormalizedSessionInfo(
            id: "fixture-\(relativeLocator(for: url).replacingOccurrences(of: "/", with: "-"))",
            source: source,
            startTime: startTime,
            cwd: root.deletingLastPathComponent().path,
            project: "engram-fixtures",
            model: "fixture",
            messageCount: 1,
            userMessageCount: 1,
            assistantMessageCount: 0,
            toolMessageCount: 0,
            systemMessageCount: 0,
            summary: url.deletingPathExtension().lastPathComponent,
            filePath: locator,
            sizeBytes: Int64(data.count)
        )
        return .success(IndexingScan(info: info, messages: [message]))
    }

    func isAccessible(locator: String) async -> Bool {
        FileManager.default.isReadableFile(atPath: locator)
    }

    private func relativeLocator(for url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

private final class PerformanceIndexingSink: IndexingWriteSink {
    private let writer: EngramDatabaseWriter

    init(writer: EngramDatabaseWriter) {
        self.writer = writer
    }

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        try writer.write { db in
            try SessionBatchUpsert(db: db).upsertBatch(snapshots, reason: reason)
        }
    }

    func knownFileIndexStates(source: SourceName, locators: [String]) throws -> [String: FileIndexState] {
        try writer.knownFileIndexStates(source: source, locators: locators)
    }

    func upsertFileIndexState(_ state: FileIndexState) throws {
        try writer.upsertFileIndexState(state)
    }
}

private final class LockedResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func value() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private enum PerformanceTestError: Error, CustomStringConvertible {
    case missingFixture(String)
    case timedOut
    case missingResult

    var description: String {
        switch self {
        case .missingFixture(let path):
            "generated session fixture root is missing: \(path)"
        case .timedOut:
            "async indexer operation timed out"
        case .missingResult:
            "async indexer operation completed without a result"
        }
    }
}

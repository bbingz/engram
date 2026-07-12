import Foundation
import XCTest
@testable import EngramCoreRead

final class ArchiveV2RecentAdapterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-v2-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testPeriodicFactoryPreservesExactBoundaryOnlyForClaudeAndCodex() {
        let adapters = SessionAdapterFactory.recentActiveAdapters(
            now: Date(timeIntervalSince1970: 1_800),
            days: 2
        )
        let exactSources = Set(
            adapters.compactMap { ($0 as? any ExactArchiveSourceAdapter)?.source }
        )

        XCTAssertEqual(exactSources, [.claudeCode, .codex])
        for adapter in adapters where ![SourceName.claudeCode, .codex].contains(adapter.source) {
            XCTAssertFalse(
                adapter is any ExactArchiveSourceAdapter,
                "\(adapter.source) must not be promoted into exact capture"
            )
        }
    }

    func testPeriodicRecentDayRootsHaveAHardUpperBound() {
        let adapters = SessionAdapterFactory.recentCodexAdapters(
            now: Date(timeIntervalSince1970: 1_800_000_000),
            days: 10_000
        )

        XCTAssertEqual(adapters.count, 7)
    }

    func testExactRecentWrapperKeepsDescriptorAndAddsBoundedDeduplicatedRetryLocators() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = try makeFile("recent.jsonl", modifiedAt: now.addingTimeInterval(-60))
        let old1 = try makeFile("old-1.jsonl", modifiedAt: now.addingTimeInterval(-3 * 86_400))
        let old2 = try makeFile("old-2.jsonl", modifiedAt: now.addingTimeInterval(-4 * 86_400))
        let old3 = try makeFile("old-3.jsonl", modifiedAt: now.addingTimeInterval(-5 * 86_400))
        let base = SyntheticExactRecentAdapter(locators: [recent.path, old1.path, old2.path, old3.path])
        let wrapped = RecentlyModifiedExactArchiveSourceAdapter(
            base: base,
            modifiedSince: now.addingTimeInterval(-2 * 86_400),
            retryLocators: [old1.path, old1.path, old2.path, old3.path],
            maximumRetryLocators: 2
        )

        let locators = try await wrapped.listSessionLocators()
        let descriptor = try await wrapped.archiveSourceDescriptor(locator: old1.path)
        let baseDescriptor = try await base.archiveSourceDescriptor(locator: old1.path)
        let erased: any SessionAdapter = wrapped

        XCTAssertEqual(locators, [recent.path, old1.path, old2.path])
        XCTAssertEqual(descriptor, baseDescriptor)
        XCTAssertTrue(erased is any ExactArchiveSourceAdapter)
    }

    func testRetryLocatorsRejectRelativeNULAndNonNormalizedValues() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = try makeFile("recent.jsonl", modifiedAt: now.addingTimeInterval(-60))
        let old = try makeFile("old.jsonl", modifiedAt: now.addingTimeInterval(-3 * 86_400))
        let base = SyntheticExactRecentAdapter(locators: [recent.path, old.path])
        let wrapped = RecentlyModifiedExactArchiveSourceAdapter(
            base: base,
            modifiedSince: now.addingTimeInterval(-2 * 86_400),
            retryLocators: [
                "relative.jsonl",
                "\(old.deletingLastPathComponent().path)/./old.jsonl",
                "\(old.path)\0suffix",
                old.path,
            ],
            maximumRetryLocators: 10
        )

        let locators = try await wrapped.listSessionLocators()
        XCTAssertEqual(locators, [recent.path, old.path])
    }

    func testZeroRetryBoundAddsNoOldLocator() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = try makeFile("recent.jsonl", modifiedAt: now.addingTimeInterval(-60))
        let old = try makeFile("old.jsonl", modifiedAt: now.addingTimeInterval(-3 * 86_400))
        let wrapped = RecentlyModifiedExactArchiveSourceAdapter(
            base: SyntheticExactRecentAdapter(locators: [recent.path, old.path]),
            modifiedSince: now.addingTimeInterval(-2 * 86_400),
            retryLocators: [old.path],
            maximumRetryLocators: 0
        )

        let locators = try await wrapped.listSessionLocators()
        XCTAssertEqual(locators, [recent.path])
    }

    func testOrdinaryRecentWrapperCannotImpersonateExactAdapter() {
        let wrapped = RecentlyModifiedSessionAdapter(
            base: SyntheticNonExactRecentAdapter(),
            modifiedSince: .distantPast
        )

        XCTAssertFalse(wrapped is any ExactArchiveSourceAdapter)
    }

    func testExactLocatorSubsetFailsClosedForLocatorOutsideItsAllowlist() async throws {
        let allowed = try makeFile("allowed.jsonl", modifiedAt: .distantPast)
        let disallowed = try makeFile("disallowed.jsonl", modifiedAt: .distantPast)
        let adapters = SessionAdapterFactory.recentActiveAdapters(
            now: Date(timeIntervalSince1970: 10_000),
            days: 1,
            priorTransientRetryLocators: [.codex: [allowed.path]],
            maximumRetryLocatorsPerSource: 1
        )
        let subset = try XCTUnwrap(adapters.last { $0.source == .codex })
        let listed = try await subset.listSessionLocators()
        XCTAssertEqual(listed, [allowed.path])

        let disallowedAccessible = await subset.isAccessible(locator: disallowed.path)
        XCTAssertFalse(
            disallowedAccessible,
            "an IndexJobRunner lookup outside the capture allowlist must not reach the base adapter"
        )
    }

    func testCapturedIndexProjectionFailsClosedAcrossEveryParserEntryPoint() async throws {
        let allowed = try makeFile("captured.jsonl", modifiedAt: .distantPast)
        let disallowed = try makeFile("uncaptured.jsonl", modifiedAt: .distantPast)
        let projected = SessionAdapterFactory.indexingAdapters(
            from: [SyntheticExactRecentAdapter(locators: [allowed.path, disallowed.path])],
            capturedExactLocators: [.claudeCode: [allowed.path]]
        )
        let adapter = try XCTUnwrap(projected.first)

        let projectedLocators = try await adapter.listSessionLocators()
        XCTAssertEqual(projectedLocators, [allowed.path])
        _ = try await adapter.parseSessionInfo(locator: allowed.path)

        do {
            _ = try await adapter.parseSessionInfo(locator: disallowed.path)
            XCTFail("parseSessionInfo accepted an uncaptured locator")
        } catch {}
        do {
            _ = try await adapter.streamMessages(
                locator: disallowed.path,
                options: StreamMessagesOptions()
            )
            XCTFail("streamMessages accepted an uncaptured locator")
        } catch {}
        do {
            _ = try await adapter.streamMessagesWithMetadata(
                locator: disallowed.path,
                options: StreamMessagesOptions()
            )
            XCTFail("streamMessagesWithMetadata accepted an uncaptured locator")
        } catch {}
        do {
            _ = try await adapter.scanForIndexing(locator: disallowed.path)
            XCTFail("scanForIndexing accepted an uncaptured locator")
        } catch {}
        let disallowedAccessible = await adapter.isAccessible(locator: disallowed.path)
        XCTAssertFalse(disallowedAccessible)
    }

    func testExactAdapterEnumerationCooperativelyObservesPreexistingCancellation() async throws {
        let claudeProject = root.appendingPathComponent("claude/project", isDirectory: true)
        let codexDay = root.appendingPathComponent("codex/2026/07/12", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: claudeProject.appendingPathComponent("session.jsonl"))
        try Data("{}\n".utf8).write(to: codexDay.appendingPathComponent("rollout-session.jsonl"))
        let adapters: [any SessionAdapter] = [
            ClaudeCodeAdapter(projectsRoot: root.appendingPathComponent("claude").path),
            CodexAdapter(sessionsRoot: root.appendingPathComponent("codex").path),
        ]

        for adapter in adapters {
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return try await adapter.listSessionLocators()
            }
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("\(adapter.source) enumeration ignored cancellation")
            } catch is CancellationError {
                // expected
            }
        }
    }

    private func makeFile(_ name: String, modifiedAt: Date) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }
}

private final class SyntheticExactRecentAdapter: ExactArchiveSourceAdapter, @unchecked Sendable {
    let source: SourceName = .claudeCode
    private let locators: [String]

    init(locators: [String]) {
        self.locators = locators
    }

    func detect() async -> Bool { true }

    func listSessionLocators() async throws -> [String] {
        locators
    }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        try ArchiveSourceDescriptor.singleFile(
            locator: locator,
            sourceURL: URL(fileURLWithPath: locator),
            replayRelativePath: "fixtures/\(URL(fileURLWithPath: locator).lastPathComponent)"
        )
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.noVisibleMessages)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func isAccessible(locator: String) async -> Bool {
        FileManager.default.fileExists(atPath: locator)
    }
}

private final class SyntheticNonExactRecentAdapter: SessionAdapter, @unchecked Sendable {
    let source: SourceName = .kimi

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.noVisibleMessages)
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func isAccessible(locator: String) async -> Bool { false }
}

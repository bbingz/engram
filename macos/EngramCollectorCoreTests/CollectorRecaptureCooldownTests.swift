import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

/// K6 churn control: a large locator captured recently is deferred until the
/// re-capture window elapses, then its latest generation is captured once.
final class CollectorRecaptureCooldownTests: XCTestCase {
    private static func wallClock() -> Int64 { Int64(Date().timeIntervalSince1970) }

    func testLargeRecaptureWaitsForWindowThenCapturesLatestGeneration() async throws {
        let fixture = try CooldownFixture()
        defer { fixture.remove() }
        var budget = CooldownFixture.budget()
        budget.recaptureCooldownMinimumBytes = 1
        budget.recaptureCooldownSeconds = 600
        let worker = try fixture.worker(budget: budget)
        let start = Self.wallClock()

        let first = try await worker.captureOnce(now: start)
        XCTAssertEqual(first.captured, 1, "first capture of a locator is never delayed")
        let capturedAt = try XCTUnwrap(fixture.lastCaptureEpoch())

        try fixture.rewrite("revision 2")
        let cooling = try await worker.captureOnce(now: start + 1)
        XCTAssertEqual(cooling.captured, 0)
        XCTAssertEqual(cooling.deferred, 1)
        XCTAssertEqual(try fixture.captureCount(), 1, "no new spool generation inside the window")
        XCTAssertEqual(try fixture.locatorText("last_error"), "recaptureCooldown")
        XCTAssertEqual(try fixture.locatorInteger("retry_not_before"), capturedAt + 600)
        XCTAssertEqual(try fixture.pendingDirty(), 1, "the dirty revision is retained")

        // A later native change re-dirties the locator but cannot bypass the window.
        try fixture.rewrite("revision 3")
        let again = try await worker.captureOnce(now: start + 2)
        XCTAssertEqual(again.captured, 0)
        XCTAssertEqual(try fixture.captureCount(), 1)
        XCTAssertEqual(try fixture.locatorInteger("retry_not_before"), capturedAt + 600)

        let due = try await worker.captureOnce(now: capturedAt + 600)
        XCTAssertEqual(due.captured, 1)
        XCTAssertEqual(try fixture.captureCount(), 2)
        XCTAssertEqual(try fixture.pendingDirty(), 0)
        XCTAssertTrue(try fixture.latestCaptureContains("revision 3"), "the window captures the latest generation")
    }

    func testSmallLocatorsAndDisabledWindowRecaptureImmediately() async throws {
        for (minimumBytes, seconds) in [(Int64(8 * 1024 * 1024), Int64(600)), (Int64(1), Int64(0))] {
            let fixture = try CooldownFixture()
            defer { fixture.remove() }
            var budget = CooldownFixture.budget()
            budget.recaptureCooldownMinimumBytes = minimumBytes
            budget.recaptureCooldownSeconds = seconds
            let worker = try fixture.worker(budget: budget)
            let start = Self.wallClock()
            _ = try await worker.captureOnce(now: start)
            try fixture.rewrite("revision 2")
            let next = try await worker.captureOnce(now: start + 1)
            XCTAssertEqual(next.captured, 1, "minimumBytes=\(minimumBytes) seconds=\(seconds)")
            XCTAssertEqual(try fixture.captureCount(), 2)
        }
    }

    func testClockMovedBeforePriorCaptureDoesNotStrandWork() async throws {
        let fixture = try CooldownFixture()
        defer { fixture.remove() }
        var budget = CooldownFixture.budget()
        budget.recaptureCooldownMinimumBytes = 1
        let worker = try fixture.worker(budget: budget)
        let start = Self.wallClock()
        _ = try await worker.captureOnce(now: start)
        try fixture.rewrite("revision 2")
        let rolledBack = try await worker.captureOnce(now: start - 3_600)
        XCTAssertEqual(rolledBack.captured, 1)
        XCTAssertEqual(try fixture.captureCount(), 2)
    }

    func testOtherLocatorsStillCaptureWhileOneCools() async throws {
        let fixture = try CooldownFixture()
        defer { fixture.remove() }
        var budget = CooldownFixture.budget()
        budget.recaptureCooldownMinimumBytes = 1
        let worker = try fixture.worker(budget: budget)
        let start = Self.wallClock()
        _ = try await worker.captureOnce(now: start)
        try fixture.rewrite("revision 2")
        try fixture.addSecondLocator()
        let cycle = try await worker.captureOnce(now: start + 1)
        XCTAssertEqual(cycle.captured, 1, "the new locator is a first capture")
        XCTAssertEqual(cycle.deferred, 1, "the recently captured locator cools")
        XCTAssertEqual(try fixture.captureCount(), 2)
    }

    func testInvalidWindowIsRejected() throws {
        let fixture = try CooldownFixture()
        defer { fixture.remove() }
        for (seconds, bytes) in [(Int64(-1), Int64(0)), (Int64(86_401), Int64(0)), (Int64(600), Int64(-1))] {
            var budget = CooldownFixture.budget()
            budget.recaptureCooldownSeconds = seconds
            budget.recaptureCooldownMinimumBytes = bytes
            XCTAssertThrowsError(try fixture.worker(budget: budget)) { error in
                XCTAssertEqual(error as? CollectorPublicationWorkerError, .invalidBudget)
            }
        }
    }
}

private final class CooldownFixture {
    static let machine = "11111111-2222-3333-4444-666666666666"
    let base: URL
    let shadow: URL
    let captureRoot: URL
    let identity: URL
    let project: URL
    let codexRoot: URL
    let owner: CollectorInventoryOwner
    let catalog: ArchiveCatalog
    let cas: ImmutableArchiveCAS
    let codex: CollectorRootConfiguration
    private let path = "codex-cooldown.jsonl"

    static func budget() -> CollectorPublicationBudget {
        var budget = CollectorPublicationBudget()
        budget.minimumFreeDiskBytes = 0
        return budget
    }

    init() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cleanupBase = checkout.appendingPathComponent(".engram-cooldown-test-\(UUID().uuidString)")
        base = cleanupBase
        var ready = false
        defer { if !ready { try? FileManager.default.removeItem(at: cleanupBase) } }
        shadow = base.appendingPathComponent("shadow")
        captureRoot = base.appendingPathComponent("capture")
        identity = base.appendingPathComponent("identity/archive.sqlite")
        project = base.appendingPathComponent("project")
        codexRoot = base.appendingPathComponent("codex")
        for url in [base, shadow, captureRoot, identity.deletingLastPathComponent(), project, codexRoot] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        }
        for url in [identity, shadow.appendingPathComponent("archive.sqlite")] {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [Self.machine])
            }
            try queue.close()
            guard chmod(url.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
        }
        catalog = try ArchiveCatalog(root: captureRoot, machineID: Self.machine)
        try catalog.migrate()
        cas = try ImmutableArchiveCAS(root: captureRoot)
        owner = try XCTUnwrap(CollectorInventoryOwner.open(
            enabled: true, shadowRoot: shadow, identityCatalog: identity, ownerRunID: UUID().uuidString
        ))
        codex = CollectorRootConfiguration(rootID: "daily-codex", source: .codex, rootPath: codexRoot.path, revision: 1)
        _ = try owner.enrollAndActivateRoot(codex)
        try write(codexBytes(text: "revision 1"), to: codexRoot.appendingPathComponent(path))
        try applyDirty([path])
        ready = true
    }

    func remove() {
        do {
            try catalog.close()
            try owner.close()
            try FileManager.default.removeItem(at: base)
        } catch {
            XCTFail("Cooldown fixture retained at \(base.path): \(error)")
        }
    }

    func worker(budget: CollectorPublicationBudget) throws -> CollectorPublicationWorker {
        try CollectorPublicationWorker(
            owner: owner, catalog: catalog, cas: cas, roots: [codex],
            replicas: [
                .init(replicaID: "hq", baseURL: URL(string: "http://127.0.0.1:1")!, bearerToken: "synthetic-hq-cooldown"),
                .init(replicaID: "m1", baseURL: URL(string: "http://127.0.0.1:2")!, bearerToken: "synthetic-m1-cooldown"),
            ],
            policy: { try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.codex]) },
            budget: budget,
            testHooks: .init(beforeRequest: { _, _ in throw CollectorPublicationWorkerError.transport })
        )
    }

    func rewrite(_ text: String) throws {
        try write(codexBytes(text: text), to: codexRoot.appendingPathComponent(path))
        try applyDirty([path])
    }

    func addSecondLocator() throws {
        try write(codexBytes(text: "second locator"), to: codexRoot.appendingPathComponent("codex-second.jsonl"))
        try applyDirty(["codex-second.jsonl"])
    }

    func captureCount() throws -> Int {
        try owner.publicationIntents(limit: 64).filter { $0.rootID == codex.rootID }.count
    }

    func lastCaptureEpoch() throws -> Int64? {
        guard let id = try locatorText("last_capture_id"), let capture = try catalog.capture(captureID: id) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: capture.capturedAt).map { Int64($0.timeIntervalSince1970.rounded(.down)) }
    }

    func latestCaptureContains(_ text: String) throws -> Bool {
        guard let id = try locatorText("last_capture_id"), let capture = try catalog.capture(captureID: id) else { return false }
        let current = try Data(contentsOf: codexRoot.appendingPathComponent(path))
        return capture.rawByteCount == Int64(current.count) && String(decoding: current, as: UTF8.self).contains(text)
    }

    func pendingDirty() throws -> Int {
        try read { try XCTUnwrap(Int.fetchOne($0, sql: """
            SELECT count(*) FROM collector_locators WHERE root_id = ? AND dirty_revision > acknowledged_revision
            """, arguments: [self.codex.rootID])) }
    }

    func locatorText(_ column: String) throws -> String? {
        try read { try String.fetchOne($0, sql: "SELECT \(column) FROM collector_locators WHERE relative_path = ?", arguments: [self.path]) }
    }

    func locatorInteger(_ column: String) throws -> Int64? {
        try read { try Int64.fetchOne($0, sql: "SELECT \(column) FROM collector_locators WHERE relative_path = ?", arguments: [self.path]) }
    }

    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: shadow.appendingPathComponent("inventory/inventory.sqlite").path, configuration: configuration
        )
        defer { try? queue.close() }
        return try queue.read(body)
    }

    private func applyDirty(_ paths: [String]) throws {
        let checkpoint = try owner.rootState(rootID: codex.rootID)?.eventCheckpoint
        _ = try owner.applyEvents(
            configuration: codex,
            expectedCheckpoint: checkpoint,
            nextCheckpoint: .init(epoch: "codex-events", cursor: UUID().uuidString),
            dirtyRelativePaths: paths,
            budget: .init(maxIncomingPaths: 16, maxPathUTF8Bytes: 1_024, maxTotalPathUTF8Bytes: 4_096, maxCheckpointUTF8Bytes: 512)
        )
    }

    private func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
    }

    private func codexBytes(text: String) throws -> Data {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "cooldown-codex", "cwd": project.path]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": text]],
            ]],
        ]
        return try rows.reduce(into: Data()) { data, row in
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(10)
        }
    }
}

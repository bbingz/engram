import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore

/// Repro: `for root in roots { guard remainingFiles > 0 else { break } }` plus
/// `claimDirty(..., limit: remainingFiles)` lets the first configured root
/// consume the whole per-cycle file budget while later dirty roots stay at
/// `last_error NULL` and zero publications.
final class CollectorRootFairnessTests: XCTestCase {
    func testLaterEnabledRootCapturesWhileFirstRootKeepsBacklog_repro() async throws {
        for maxCaptureFiles in [1, 2] {
            let fixture = try FairnessFixture()
            defer { fixture.remove() }
            var budget = CollectorPublicationBudget()
            budget.maxCaptureFiles = maxCaptureFiles
            budget.minimumFreeDiskBytes = 0
            let worker = try fixture.worker(budget: budget)
            let cycles = 6
            var captured = 0
            for now in 1...Int64(cycles) {
                try fixture.redirtyFirstRoot()
                let cycle = try await worker.runOnce(now: now)
                XCTAssertLessThanOrEqual(cycle.captured, maxCaptureFiles, "cycle \(now) file budget")
                captured += cycle.captured
            }
            let intents = try fixture.owner.publicationIntents(limit: 64)
            XCTAssertGreaterThan(intents.filter { $0.rootID == fixture.codex.rootID }.count, 0)
            XCTAssertLessThanOrEqual(captured, maxCaptureFiles * cycles)
            XCTAssertGreaterThan(
                try fixture.dirtyLocatorCount(fixture.codex), 0,
                "first root must still have uncaptured dirty work"
            )
            XCTAssertGreaterThan(
                intents.filter { $0.rootID == fixture.claude.rootID }.count, 0,
                "maxCaptureFiles=\(maxCaptureFiles): later Claude root must capture within \(cycles) cycles while Codex keeps a backlog"
            )
        }
    }
}

private final class FairnessFixture {
    static let machine = "11111111-2222-3333-4444-555555555555"
    let base: URL
    let shadow: URL
    let captureRoot: URL
    let identity: URL
    let project: URL
    let codexRoot: URL
    let claudeRoot: URL
    let owner: CollectorInventoryOwner
    let catalog: ArchiveCatalog
    let cas: ImmutableArchiveCAS
    let codex: CollectorRootConfiguration
    let claude: CollectorRootConfiguration
    private let firstRelativePaths: [String]
    private let claudeRelativePath = "claude-one.jsonl"
    private var firstRevision = 0

    init() throws {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cleanupBase = checkout.appendingPathComponent(".engram-fairness-test-\(UUID().uuidString)")
        base = cleanupBase
        var ready = false
        defer { if !ready { try? FileManager.default.removeItem(at: cleanupBase) } }
        shadow = base.appendingPathComponent("shadow")
        captureRoot = base.appendingPathComponent("capture")
        identity = base.appendingPathComponent("identity/archive.sqlite")
        project = base.appendingPathComponent("project")
        codexRoot = base.appendingPathComponent("codex")
        claudeRoot = base.appendingPathComponent("claude")
        for url in [base, shadow, captureRoot, identity.deletingLastPathComponent(), project, codexRoot, claudeRoot] {
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
        claude = CollectorRootConfiguration(
            rootID: "daily-claude", source: .claudeCode, rootPath: claudeRoot.path, revision: 1
        )
        _ = try owner.enrollAndActivateRoot(codex)
        _ = try owner.enrollAndActivateRoot(claude)
        firstRelativePaths = (0..<6).map { "codex-\($0).jsonl" }
        for (index, name) in firstRelativePaths.enumerated() {
            try write(codexBytes(text: "codex backlog \(index)"), to: codexRoot.appendingPathComponent(name))
        }
        try write(claudeBytes(text: "claude later root"), to: claudeRoot.appendingPathComponent(claudeRelativePath))
        try applyDirty(codex, paths: firstRelativePaths, epoch: "codex-events")
        try applyDirty(claude, paths: [claudeRelativePath], epoch: "claude-events")
        ready = true
    }

    func remove() {
        do {
            try catalog.close()
            try owner.close()
            try FileManager.default.removeItem(at: base)
        } catch {
            XCTFail("Fairness fixture retained at \(base.path): \(error)")
        }
    }

    func redirtyFirstRoot() throws {
        firstRevision += 1
        for (index, name) in firstRelativePaths.enumerated() {
            try write(codexBytes(text: "codex backlog \(index) revision \(firstRevision)"),
                to: codexRoot.appendingPathComponent(name))
        }
        try applyDirty(codex, paths: firstRelativePaths, epoch: "codex-events")
    }

    func dirtyLocatorCount(_ root: CollectorRootConfiguration) throws -> Int {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: shadow.appendingPathComponent("inventory/inventory.sqlite").path,
            configuration: configuration
        )
        defer { try? queue.close() }
        return try queue.read {
            try XCTUnwrap(Int.fetchOne($0, sql: """
                SELECT count(*) FROM collector_locators
                WHERE root_id = ? AND dirty_revision > acknowledged_revision
                """, arguments: [root.rootID]))
        }
    }

    func worker(budget: CollectorPublicationBudget) throws -> CollectorPublicationWorker {
        try CollectorPublicationWorker(
            owner: owner, catalog: catalog, cas: cas, roots: [codex, claude],
            replicas: [
                .init(replicaID: "hq", baseURL: URL(string: "http://127.0.0.1:1")!, bearerToken: "synthetic-hq-fairness"),
                .init(replicaID: "m1", baseURL: URL(string: "http://127.0.0.1:2")!, bearerToken: "synthetic-m1-fairness"),
            ],
            policy: { try CollectorPrivacyPolicy(revision: 1, excludedProjectRoots: [], allowedSources: [.codex, .claudeCode]) },
            budget: budget,
            testHooks: .init(beforeRequest: { _, _ in throw CollectorPublicationWorkerError.transport })
        )
    }

    private func applyDirty(_ root: CollectorRootConfiguration, paths: [String], epoch: String) throws {
        let checkpoint = try owner.rootState(rootID: root.rootID)?.eventCheckpoint
        _ = try owner.applyEvents(
            configuration: root,
            expectedCheckpoint: checkpoint,
            nextCheckpoint: .init(epoch: epoch, cursor: UUID().uuidString),
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
            ["type": "session_meta", "payload": ["id": "fairness-codex", "cwd": project.path]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": text]],
            ]],
        ]
        return try encodeLines(rows)
    }

    private func claudeBytes(text: String) throws -> Data {
        try encodeLines([[
            "type": "assistant", "sessionId": "fairness-claude", "cwd": project.path,
            "message": ["model": "claude-sonnet-4", "content": text],
        ]])
    }

    private func encodeLines(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { data, row in
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(10)
        }
    }
}

import Darwin
import Foundation
import XCTest
@testable import EngramRemoteServerCore

final class ArchiveRemoteTelemetryStoreTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)

    func testRecordAccumulatesSortedEndpointAndDiskMetrics() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let store = try ArchiveRemoteTelemetryStore(
            archiveRoot: root,
            serverID: "hq",
            sourceRevision: revision,
            now: clock.now
        )

        await store.record(.init(
            endpoint: "object",
            method: "PUT",
            statusCode: 201,
            durationMs: 4,
            requestBytes: 12,
            responseBytes: 0,
            archiveMutation: true
        ))
        await store.record(.init(
            endpoint: "manifest",
            method: "GET",
            statusCode: 404,
            durationMs: 6,
            requestBytes: 3,
            responseBytes: 5,
            archiveMutation: false
        ))
        await store.record(.init(
            endpoint: "object",
            method: "GET",
            statusCode: 500,
            durationMs: 8,
            requestBytes: 0,
            responseBytes: 2,
            archiveMutation: false
        ))

        let snapshot = await store.status(forcePersist: false)
        XCTAssertEqual(snapshot.requestCount, 3)
        XCTAssertEqual(snapshot.successCount, 1)
        XCTAssertEqual(snapshot.clientErrorCount, 1)
        XCTAssertEqual(snapshot.serverErrorCount, 1)
        XCTAssertEqual(snapshot.requestBytes, 15)
        XCTAssertEqual(snapshot.responseBytes, 7)
        XCTAssertEqual(snapshot.lastArchiveMutationAt, "2026-07-12T10:00:00.000Z")
        XCTAssertEqual(snapshot.endpoints.map(\.endpoint), ["manifest", "object"])
        XCTAssertEqual(snapshot.endpoints[1].requestCount, 2)
        XCTAssertEqual(snapshot.endpoints[1].errorCount, 1)
        XCTAssertEqual(snapshot.endpoints[1].totalDurationMs, 12)
        XCTAssertEqual(snapshot.endpoints[1].maximumDurationMs, 8)
        XCTAssertNotNil(snapshot.diskAvailableBytes)
        XCTAssertNotNil(snapshot.diskTotalBytes)
        XCTAssertLessThanOrEqual(snapshot.diskAvailableBytes!, snapshot.diskTotalBytes!)
    }

    func testRecordMapsOnlyFixedErrorCategories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let store = try makeStore(root: root, clock: clock)
        let cases: [(Int, String)] = [
            (401, "unauthorized"),
            (400, "malformed_request"),
            (404, "not_found"),
            (409, "conflict"),
            (413, "payload_too_large"),
            (422, "invalid_content"),
            (507, "storage_unavailable"),
            (500, "internal_error"),
        ]

        for (statusCode, _) in cases {
            await store.record(.init(
                endpoint: "receipt",
                method: "PUT",
                statusCode: statusCode,
                durationMs: 1,
                requestBytes: 0,
                responseBytes: 0,
                archiveMutation: false
            ))
        }

        let snapshot = await store.status(forcePersist: false)
        XCTAssertEqual(snapshot.recentErrors.map(\.category), cases.map(\.1))
        XCTAssertEqual(snapshot.recentErrors.map(\.statusCode), cases.map(\.0))
    }

    func testRecordRetainsOnlyNewestHundredSanitizedErrors() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let store = try makeStore(root: root, clock: clock)

        for index in 0..<105 {
            clock.set(instant(String(format: "2026-07-12T10:00:00.%03dZ", index)))
            await store.record(.init(
                endpoint: "/v2/archive/objects/secret-digest?token=secret",
                method: "GET",
                statusCode: 404,
                durationMs: 1,
                requestBytes: 0,
                responseBytes: 0,
                archiveMutation: false
            ))
        }

        let snapshot = await store.status(forcePersist: false)
        XCTAssertEqual(snapshot.recentErrors.count, 100)
        XCTAssertEqual(snapshot.recentErrors.first?.timestamp, "2026-07-12T10:00:00.005Z")
        XCTAssertEqual(snapshot.recentErrors.last?.timestamp, "2026-07-12T10:00:00.104Z")
        XCTAssertTrue(snapshot.recentErrors.allSatisfy { $0.endpoint == "unknown" })
        let encoded = try ArchiveCanonicalJSON.encode(snapshot)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
        XCTAssertLessThanOrEqual(encoded.count, ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes)
    }

    func testReloadedCountersAndEndpointTotalsSaturate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let snapshot = try ArchiveRemoteTelemetrySnapshot(
            serverID: "hq",
            sourceRevision: revision,
            processStartedAt: "2026-07-12T09:00:00.000Z",
            snapshotAt: "2026-07-12T09:59:00.000Z",
            uptimeSeconds: 3_540,
            diskAvailableBytes: 1,
            diskTotalBytes: 2,
            requestCount: .max,
            successCount: .max,
            clientErrorCount: .max,
            serverErrorCount: .max,
            requestBytes: .max,
            responseBytes: .max,
            lastArchiveMutationAt: nil,
            persistenceError: nil,
            endpoints: [
                try .init(
                    endpoint: "object",
                    requestCount: .max,
                    errorCount: .max,
                    totalDurationMs: Double.greatestFiniteMagnitude,
                    maximumDurationMs: Double.greatestFiniteMagnitude,
                    requestBytes: .max,
                    responseBytes: .max
                ),
            ],
            recentErrors: []
        )
        try writeSnapshot(snapshot, under: root)
        let store = try makeStore(root: root, clock: clock)

        await store.record(.init(
            endpoint: "object",
            method: "PUT",
            statusCode: 500,
            durationMs: Double.greatestFiniteMagnitude,
            requestBytes: .max,
            responseBytes: .max,
            archiveMutation: false
        ))

        let result = await store.status(forcePersist: false)
        XCTAssertEqual(result.requestCount, Int64.max)
        XCTAssertEqual(result.successCount, Int64.max)
        XCTAssertEqual(result.clientErrorCount, Int64.max)
        XCTAssertEqual(result.serverErrorCount, Int64.max)
        XCTAssertEqual(result.requestBytes, Int64.max)
        XCTAssertEqual(result.responseBytes, Int64.max)
        XCTAssertEqual(result.endpoints[0].requestCount, Int64.max)
        XCTAssertEqual(result.endpoints[0].errorCount, Int64.max)
        XCTAssertEqual(result.endpoints[0].requestBytes, Int64.max)
        XCTAssertEqual(result.endpoints[0].responseBytes, Int64.max)
        XCTAssertTrue(result.endpoints[0].totalDurationMs.isFinite)
    }

    func testPersistenceIsThrottledToSixtySecondsAndForceFlushesDirtyState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let writer = ArchiveTelemetryWriterProbe()
        let store = try makeStore(root: root, clock: clock, writer: writer.write)

        await store.record(successObservation)
        XCTAssertEqual(writer.count, 0)
        clock.set(instant("2026-07-12T10:00:59.000Z"))
        await store.record(successObservation)
        XCTAssertEqual(writer.count, 0)
        clock.set(instant("2026-07-12T10:01:00.000Z"))
        await store.record(successObservation)
        XCTAssertEqual(writer.count, 1)
        clock.set(instant("2026-07-12T10:01:59.000Z"))
        await store.record(successObservation)
        _ = await store.status(forcePersist: false)
        XCTAssertEqual(writer.count, 1)
        _ = await store.status(forcePersist: true)
        XCTAssertEqual(writer.count, 2)
        _ = await store.status(forcePersist: true)
        XCTAssertEqual(writer.count, 2)
    }

    func testFailedAutomaticPersistenceIsAlsoThrottledToSixtySeconds() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let writer = ArchiveTelemetryWriterProbe(shouldFail: true)
        let store = try makeStore(root: root, clock: clock, writer: writer.write)

        await store.record(successObservation)
        clock.set(instant("2026-07-12T10:01:00.000Z"))
        await store.record(successObservation)
        XCTAssertEqual(writer.count, 1)
        clock.set(instant("2026-07-12T10:01:00.001Z"))
        await store.record(successObservation)
        XCTAssertEqual(writer.count, 1)
        clock.set(instant("2026-07-12T10:02:00.000Z"))
        await store.record(successObservation)
        XCTAssertEqual(writer.count, 2)
    }

    func testStatusForcePersistsAndReloadsBoundedState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let store = try makeStore(root: root, clock: clock)
        await store.record(.init(
            endpoint: "object",
            method: "PUT",
            statusCode: 201,
            durationMs: 4,
            requestBytes: 12,
            responseBytes: 0,
            archiveMutation: true
        ))
        _ = await store.status(forcePersist: true)

        clock.set(instant("2026-07-12T10:02:00.000Z"))
        let reloaded = try makeStore(root: root, clock: clock)
        let snapshot = await reloaded.status(forcePersist: false)
        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertEqual(snapshot.lastArchiveMutationAt, "2026-07-12T10:00:00.000Z")
        XCTAssertEqual(snapshot.processStartedAt, "2026-07-12T10:02:00.000Z")
        XCTAssertEqual(snapshot.uptimeSeconds, 0)
    }

    func testCreatesPrivateTelemetryDirectoryAndSnapshotFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let store = try makeStore(root: root, clock: clock)
        await store.record(successObservation)
        _ = await store.status(forcePersist: true)

        XCTAssertEqual(try mode(of: telemetryDirectory(under: root)), 0o700)
        XCTAssertEqual(try mode(of: snapshotFile(under: root)), 0o600)
        var info = stat()
        XCTAssertEqual(lstat(snapshotFile(under: root).path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
    }

    func testReloadIgnoresCorruptOversizedAndUnsupportedSchemaSnapshots() async throws {
        for fixture in SnapshotFixture.allCases {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try createTelemetryDirectory(under: root)
            let url = snapshotFile(under: root)
            switch fixture {
            case .corrupt:
                try Data("not-json".utf8).write(to: url)
            case .oversized:
                try Data(
                    repeating: 0x41,
                    count: ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes + 1
                ).write(to: url)
            case .unsupportedSchema:
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(emptySnapshot()))
                        as? [String: Any]
                )
                object["schema"] = 2
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
            }
            XCTAssertEqual(chmod(url.path, 0o600), 0)

            let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
            let store = try makeStore(root: root, clock: clock)
            let snapshot = await store.status(forcePersist: false)
            XCTAssertEqual(snapshot.requestCount, 0, "fixture: \(fixture)")
            XCTAssertTrue(snapshot.endpoints.isEmpty, "fixture: \(fixture)")
        }
    }

    func testReloadAndPersistRejectSymlinkSnapshotWithoutTouchingTarget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-telemetry-outside-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        let original = try ArchiveCanonicalJSON.encode(emptySnapshot())
        try original.write(to: outside)
        XCTAssertEqual(chmod(outside.path, 0o600), 0)
        try createTelemetryDirectory(under: root)
        try FileManager.default.createSymbolicLink(
            at: snapshotFile(under: root),
            withDestinationURL: outside
        )
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let store = try makeStore(root: root, clock: clock)

        await store.record(successObservation)
        let snapshot = await store.status(forcePersist: true)

        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertEqual(snapshot.persistenceError, "snapshot_write_failed")
        XCTAssertEqual(try Data(contentsOf: outside), original)
        var info = stat()
        XCTAssertEqual(lstat(snapshotFile(under: root).path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testInjectedPersistenceFailureIsSanitizedAndDoesNotStopRecording() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableArchiveTelemetryClock(now: instant("2026-07-12T10:00:00.000Z"))
        let store = try makeStore(root: root, clock: clock) { _, _ in
            throw NSError(
                domain: "raw /private/archive host.example bearer-token-secret",
                code: 1
            )
        }

        await store.record(successObservation)
        let failed = await store.status(forcePersist: true)
        await store.record(successObservation)
        let stillRunning = await store.status(forcePersist: false)

        XCTAssertEqual(failed.persistenceError, "snapshot_write_failed")
        XCTAssertEqual(stillRunning.requestCount, 2)
        let json = String(
            decoding: try ArchiveCanonicalJSON.encode(stillRunning),
            as: UTF8.self
        )
        XCTAssertFalse(json.contains("/private/archive"))
        XCTAssertFalse(json.contains("host.example"))
        XCTAssertFalse(json.contains("bearer-token-secret"))
    }

    private var successObservation: ArchiveRemoteTelemetryObservation {
        .init(
            endpoint: "object",
            method: "PUT",
            statusCode: 201,
            durationMs: 1,
            requestBytes: 1,
            responseBytes: 1,
            archiveMutation: true
        )
    }

    private func makeStore(
        root: URL,
        clock: MutableArchiveTelemetryClock,
        writer: @escaping ArchiveRemoteTelemetryStore.SnapshotWriter =
            ArchiveRemoteTelemetryStore.defaultSnapshotWriter
    ) throws -> ArchiveRemoteTelemetryStore {
        try ArchiveRemoteTelemetryStore(
            archiveRoot: root,
            serverID: "hq",
            sourceRevision: revision,
            now: clock.now,
            snapshotWriter: writer
        )
    }

    private func emptySnapshot() throws -> ArchiveRemoteTelemetrySnapshot {
        try ArchiveRemoteTelemetrySnapshot(
            serverID: "hq",
            sourceRevision: revision,
            processStartedAt: "2026-07-12T09:00:00.000Z",
            snapshotAt: "2026-07-12T09:00:00.000Z",
            uptimeSeconds: 0,
            diskAvailableBytes: nil,
            diskTotalBytes: nil,
            requestCount: 0,
            successCount: 0,
            clientErrorCount: 0,
            serverErrorCount: 0,
            requestBytes: 0,
            responseBytes: 0,
            lastArchiveMutationAt: nil,
            persistenceError: nil,
            endpoints: [],
            recentErrors: []
        )
    }

    private func writeSnapshot(
        _ snapshot: ArchiveRemoteTelemetrySnapshot,
        under root: URL
    ) throws {
        try createTelemetryDirectory(under: root)
        let url = snapshotFile(under: root)
        try ArchiveCanonicalJSON.encode(snapshot).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-remote-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }

    private func createTelemetryDirectory(under root: URL) throws {
        let directory = telemetryDirectory(under: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
    }

    private func telemetryDirectory(under root: URL) -> URL {
        root.appendingPathComponent(".telemetry", isDirectory: true)
    }

    private func snapshotFile(under root: URL) -> URL {
        telemetryDirectory(under: root).appendingPathComponent("status-v1.json")
    }

    private func mode(of url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return info.st_mode & 0o777
    }

    private func instant(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }
}

private enum SnapshotFixture: CaseIterable {
    case corrupt
    case oversized
    case unsupportedSchema
}

private final class MutableArchiveTelemetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

private final class ArchiveTelemetryWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let shouldFail: Bool
    private var writes = 0

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    var count: Int {
        lock.withLock { writes }
    }

    func write(_ data: Data, _ url: URL) throws {
        lock.withLock { writes += 1 }
        if shouldFail {
            throw NSError(domain: "injected", code: 1)
        }
    }
}

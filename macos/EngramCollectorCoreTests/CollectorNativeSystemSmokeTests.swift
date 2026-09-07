import CoreServices
import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

// Uses the real default CoreServices backend, scoped to one disposable directory.
// This is a native callback smoke, not a production source or W6 latency check.
final class CollectorNativeSystemSmokeTests: XCTestCase {
    func testRealTemporaryRootReceivesRelativeFileEventAndStops() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".engram-native-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // Avoid a normalization-form assumption: FSEvents may decompose names.
        let name = "captured-\u{4e2d}.jsonl"
        let file = root.appendingPathComponent(name)
        try Data("before\n".utf8).write(to: file)
        let configuration = CollectorRootConfiguration(rootID: "native-system-smoke", source: .codex,
                                                       rootPath: root.path, revision: 1)
        let binding = try CollectorPOSIXRootEnumerator.observeRoot(configuration: configuration)
        let device = try XCTUnwrap(Int32(exactly: binding.expectedIdentity.device))
        let uuid = try XCTUnwrap(FSEventsCopyUUIDForDevice(device))
        let epoch = "fsevents-device-v1:" + (CFUUIDCreateString(nil, uuid) as String)
        // mkdir/file creation can still be in the daemon's first coalesced
        // batch. A directory event correctly seals the product adapter. Flush
        // those fixture setup events before testing an ordinary file append.
        try flushFixtureSetup(binding: binding, device: device, file: file)
        let request = CollectorEventStreamRequest(binding: binding, generation: 1, epoch: epoch,
                                                   resumeCheckpoint: nil)
        let stream = CollectorNativeEventStream(
            request: request,
            budget: .init(maxIncomingPaths: 64, maxPathUTF8Bytes: 256,
                          maxTotalPathUTF8Bytes: 8192, maxCheckpointUTF8Bytes: 512)
        )
        defer { try? stream.stop() }
        let received = expectation(description: "real native callback for exact relative Unicode path")
        let lock = NSLock()
        var matched = false
        var checkpoints: [CollectorEventCheckpoint] = []
        var losses: [CollectorEventGapReason] = []
        var histories = 0
        try stream.start { signal in
            var notify = false
            lock.withLock {
                switch signal {
                case let .batch(batch):
                    checkpoints.append(batch.nextCheckpoint)
                    if batch.dirtyRelativePaths.contains(where: { $0.utf8.elementsEqual(name.utf8) }), !matched {
                        matched = true
                        notify = true
                    }
                case .historyDone: histories += 1
                case let .loss(reason): losses.append(reason)
                case .terminated: break
                }
            }
            if notify { received.fulfill() }
            if case .batch = signal { return .queued }
            return .controlAccepted
        }
        XCTAssertEqual(lock.withLock { histories }, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("after\n".utf8))
        try handle.synchronize()
        try handle.close()
        wait(for: [received], timeout: 5)
        try stream.stop()
        try stream.stop()
        let observed = lock.withLock { (matched, checkpoints, losses) }
        XCTAssertTrue(observed.0)
        XCTAssertTrue(observed.2.isEmpty, "native loss: \(observed.2)")
        XCTAssertFalse(observed.1.isEmpty)
        for checkpoint in observed.1 {
            XCTAssertEqual(checkpoint.epoch, epoch)
            let cursor = try XCTUnwrap(UInt64(checkpoint.cursor))
            XCTAssertGreaterThan(cursor, 0)
            XCTAssertLessThan(cursor, UInt64.max)
            XCTAssertEqual(String(cursor), checkpoint.cursor)
        }
    }

    private func flushFixtureSetup(binding: CollectorPOSIXRootBinding, device: Int32, file: URL) throws {
        let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(binding.configuration.rootPath))
        defer { CollectorPOSIXDirectoryAccess.close(opened.descriptor) }
        var volume = statfs()
        guard fstatfs(opened.descriptor, &volume) == 0 else { throw SmokeSetupError.volume }
        var physicalBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = physicalBytes.withUnsafeMutableBufferPointer {
            fcntl(opened.descriptor, F_GETPATH_NOFIRMLINK, $0.baseAddress!)
        }
        guard result == 0 else { throw SmokeSetupError.path }
        let physical = String(cString: physicalBytes)
        let mount = withUnsafeBytes(of: &volume.f_mntonname) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let prefix = mount == "/" ? "/" : mount + "/"
        guard physical.utf8.starts(with: prefix.utf8) else { throw SmokeSetupError.path }
        let relative = String(physical.dropFirst(prefix.count))
        let queue = DispatchQueue(label: "engram.native.smoke.setup")
        let delivered = DispatchSemaphore(value: 0)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(delivered).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagFullHistory)
        let stream = try XCTUnwrap(FSEventStreamCreateRelativeToDevice(
            nil, { _, info, count, _, _, _ in
                guard let info, count > 0 else { return }
                Unmanaged<DispatchSemaphore>.fromOpaque(info).takeUnretainedValue().signal()
            }, &context, device, [relative] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags))
        FSEventStreamSetDispatchQueue(stream, queue)
        let started = FSEventStreamStart(stream)
        defer {
            if started { FSEventStreamStop(stream) }
            FSEventStreamInvalidate(stream)
            queue.sync {}
            withExtendedLifetime(delivered) { FSEventStreamRelease(stream) }
        }
        guard started else { throw SmokeSetupError.start }
        // An immediate FlushSync can precede kernel event delivery to the
        // daemon. First observe a live fixture callback, then flush its queue.
        let marker = try FileHandle(forWritingTo: file)
        try marker.seekToEnd()
        try marker.write(contentsOf: Data("setup-marker\n".utf8))
        try marker.synchronize()
        try marker.close()
        guard delivered.wait(timeout: .now() + 5) == .success else { throw SmokeSetupError.callback }
        // SDK guarantees delivery of already-occurred events before returning.
        // Run outside the stream callback queue; no sleeps or blind retry.
        FSEventStreamFlushSync(stream)
    }
}

private enum SmokeSetupError: Error { case volume, path, start, callback }

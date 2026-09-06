import CoreServices
import Darwin
import Foundation

enum CollectorNativeEventStreamError: Error, Equatable {
    case notImplemented
    case invalidBudget
    case invalidCheckpoint
    case invalidEpoch
    case invalidRoot
    case createFailed
    case startFailed
    case invalidState
    // Unsupported by the frozen coordinator contract. This must leave ownership
    // available for a later external stop; it must not claim that drain finished.
    case reentrantStopUnsupported
}

// Every observation is obtained outside the native callback. The production
// backend must use the held no-follow root descriptor, a freshly checked route,
// F_GETPATH_NOFIRMLINK, fstatfs, and FSEventsCopyUUIDForDevice. Filesystem volume
// UUIDs and spelling-based /Users -> /System/Volumes/Data guesses are not valid.
struct CollectorNativeRootObservation {
    let descriptorIdentity: CollectorPOSIXDirectoryIdentity
    let routeIdentity: CollectorPOSIXDirectoryIdentity
    let physicalRootPath: String
    let volumeMountPath: String
    let volumeDevice: Int64
    let eventDatabaseUUID: String?
}

struct CollectorNativeEventCreateRequest {
    let device: Int32
    let volumeRelativeRoot: String
    let sinceWhen: FSEventStreamEventId
    let flags: FSEventStreamCreateFlags
}

protocol CollectorNativeEventHandle: AnyObject {}

// Borrowed char **, flag array, and ID array are valid only until return.
// The real C callback and fixture injection MUST use this same decoding path.
// Check count before dereferencing even the pointer table; copy bounded strict
// UTF-8 bytes before admission. Never retain these pointers or dispatch work
// that uses them after return. Nil buffers intentionally support fault tests.
typealias CollectorNativeRawEventCallback = (
    _ count: Int,
    _ paths: UnsafeRawPointer?,
    _ flags: UnsafePointer<FSEventStreamEventFlags>?,
    _ ids: UnsafePointer<FSEventStreamEventId>?
) -> Void

// The single injected boundary for native resource ownership and lifecycle
// faults. It does not parse events or decide checkpoint/recovery semantics.
protocol CollectorNativeEventAPI: AnyObject {
    func openRoot(_ binding: CollectorPOSIXRootBinding) throws -> Int32
    func observeRoot(_ descriptor: Int32, binding: CollectorPOSIXRootBinding) throws -> CollectorNativeRootObservation
    func closeRoot(_ descriptor: Int32)
    func create(
        _ request: CollectorNativeEventCreateRequest,
        callback: @escaping CollectorNativeRawEventCallback
    ) throws -> (any CollectorNativeEventHandle)?
    func schedule(_ stream: any CollectorNativeEventHandle, on queue: DispatchQueue) throws
    func start(_ stream: any CollectorNativeEventHandle) -> Bool
    func stop(_ stream: any CollectorNativeEventHandle) throws
    func invalidate(_ stream: any CollectorNativeEventHandle) throws
    func drain(_ queue: DispatchQueue) throws
    func release(_ stream: any CollectorNativeEventHandle)
}

struct CollectorNativeEventStreamTestHooks {
    // Called after admission is sealed/unlocked, before waiting for start/drain.
    // This makes stop/start race tests deterministic without sleeps.
    var didSealForStop: (() -> Void)?
}

// Construction is cold, including selection of the production API. Callers own
// the synchronous, external stop obligation; a callback must never call stop.
//
// Native checkpoint and ownership contract:
// - Durable IDs are canonical decimal 1 ... UInt64.max - 1. Epoch is exactly
//   fsevents-device-v1:<canonical FSEvents database UUID>. Invalid existing state
//   fails closed, never clears or rebases a checkpoint.
// - A nil checkpoint uses SinceNow, then only after successful subscription and
//   the post-start root fence emits explicitly synthetic HistoryDone on the SAME
//   callback queue. It synthesizes no checkpoint. Non-nil waits for native replay
//   HistoryDone. FullHistory may replay lower/repeated IDs: retain ALL paths and
//   use max(previous high-water, observed IDs), never a regressing checkpoint.
// - UserDropped/KernelDropped are overflow. Directory/root structural events,
//   unknown type, Mount/Unmount, MustScan, RootChanged, and EventIdsWrapped need
//   application inventory reconciliation (continuityLoss), not a kernel-loss
//   claim. A file-level ordinary change remains an ordinary batch.
// - Validate the entire callback before admitting any batch/control; a loss
//   dominates HistoryDone and all ordinary entries in that callback. Latch once.
//   Callbacks do no Owner, filesystem, Task, or background-queue work.
// - External stop seals admission before Stop/Invalidate/queue drain/Release and
//   root close. Never hold an admission lock while draining. Normal external
//   errors must still clean owned resources. Unsupported same-callback stop must
//   fail fast without silently dropping the later external cleanup opportunity.
final class CollectorNativeEventStream: CollectorEventStream {
    private let request: CollectorEventStreamRequest
    private let budget: CollectorEventIngressBudget
    private let api: any CollectorNativeEventAPI
    private let testHooks: CollectorNativeEventStreamTestHooks
    private let condition = NSCondition()
    private let callbackQueue = DispatchQueue(label: "engram.collector.native-events")
    private let callbackKey = DispatchSpecificKey<UInt8>()
    // Lifecycle state is protected by condition. Resource fields are exclusively
    // owned by start until starting clears, then by the single cleanup caller.
    private var attemptedStart = false
    private var starting = false
    private var stopping = false
    private var stopped = false
    private var stopRequested = false
    private var admissionOpen = false
    private var deliver: ((CollectorEventStreamSignal) -> CollectorEventAdmission)?
    private var descriptor: Int32?
    private var stream: (any CollectorNativeEventHandle)?
    private var scheduled = false
    private var nativeStarted = false
    // Initialized before scheduling, subsequently used only on callbackQueue.
    private var rootPrefix: [UInt8] = []
    private var highWater: UInt64 = 0
    private var historyDone = false

    init(request: CollectorEventStreamRequest, budget: CollectorEventIngressBudget, api: (any CollectorNativeEventAPI)? = nil,
         testHooks: CollectorNativeEventStreamTestHooks = .init()) {
        self.request = request
        self.budget = budget
        self.api = api ?? CollectorNativeSystemAPI()
        self.testHooks = testHooks
        callbackQueue.setSpecific(key: callbackKey, value: 1)
    }

    func start(deliver: @escaping (CollectorEventStreamSignal) -> CollectorEventAdmission) throws {
        condition.lock()
        guard !attemptedStart, !stopped, !stopRequested else {
            condition.unlock()
            throw CollectorNativeEventStreamError.invalidState
        }
        attemptedStart = true
        starting = true
        condition.unlock()
        do {
            try checkStartMayContinue()
            guard budget.maxIncomingPaths >= 0, budget.maxPathUTF8Bytes >= 0,
                  budget.maxTotalPathUTF8Bytes >= 0, budget.maxCheckpointUTF8Bytes >= 0 else {
                throw CollectorNativeEventStreamError.invalidBudget
            }
            highWater = try validatedCursor()
            let uuid = try validatedEpoch()
            descriptor = try api.openRoot(request.binding)
            try checkStartMayContinue()
            let before = try api.observeRoot(descriptor!, binding: request.binding)
            let relativeRoot = try validate(before, uuid: uuid)
            rootPrefix = Array(relativeRoot.utf8)
            if !rootPrefix.isEmpty { rootPrefix.append(47) }
            try checkStartMayContinue()
            let createRequest = CollectorNativeEventCreateRequest(
                device: Int32(before.volumeDevice), volumeRelativeRoot: relativeRoot,
                sinceWhen: request.resumeCheckpoint == nil ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : highWater,
                flags: FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagFullHistory))
            guard let created = try api.create(createRequest, callback: { [weak self] count, paths, flags, ids in
                self?.receive(count: count, paths: paths, flags: flags, ids: ids)
            }) else { throw CollectorNativeEventStreamError.createFailed }
            stream = created
            try checkStartMayContinue()
            try api.schedule(created, on: callbackQueue)
            scheduled = true
            try checkStartMayContinue()
            condition.lock()
            self.deliver = deliver
            admissionOpen = !stopRequested
            condition.unlock()
            // Publish started ownership before checking cancellation or stop:
            // Start may return true after either happened inside the native call.
            nativeStarted = api.start(created)
            guard nativeStarted else { throw CollectorNativeEventStreamError.startFailed }
            try checkStartMayContinue()
            let after = try api.observeRoot(descriptor!, binding: request.binding)
            _ = try validate(after, uuid: uuid)
            guard before.physicalRootPath.utf8.elementsEqual(after.physicalRootPath.utf8),
                  before.volumeMountPath.utf8.elementsEqual(after.volumeMountPath.utf8),
                  before.volumeDevice == after.volumeDevice else {
                throw CollectorNativeEventStreamError.invalidRoot
            }
            try checkStartMayContinue()
            if request.resumeCheckpoint == nil {
                // SinceNow has no native HistoryDone. This is explicitly a
                // synthetic subscription fence, never a synthetic checkpoint.
                callbackQueue.sync {
                    if !historyDone, admit(.historyDone) { historyDone = true }
                }
            }
            try checkStartMayContinue()
            condition.lock()
            starting = false
            condition.broadcast()
            condition.unlock()
        } catch {
            sealAdmission()
            _ = cleanResources()
            condition.lock()
            stopped = true
            starting = false
            self.deliver = nil
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    func stop() throws {
        // Never consume the external cleanup opportunity or enqueue hidden work
        // when the frozen coordinator's non-reentrant contract is violated.
        guard DispatchQueue.getSpecific(key: callbackKey) == nil else {
            throw CollectorNativeEventStreamError.reentrantStopUnsupported
        }
        condition.lock()
        stopRequested = true
        admissionOpen = false
        condition.unlock()
        testHooks.didSealForStop?()
        condition.lock()
        while starting || stopping { condition.wait() }
        guard !stopped else { condition.unlock(); return }
        stopping = true
        condition.unlock()
        // Cancellation does not cancel resource ownership or the drain barrier.
        let failure = cleanResources()
        condition.lock()
        stopped = true
        stopping = false
        deliver = nil
        condition.broadcast()
        condition.unlock()
        if let failure { throw failure }
    }

    private func checkStartMayContinue() throws {
        try Task.checkCancellation()
        condition.lock()
        let cancelled = stopRequested
        condition.unlock()
        if cancelled { throw CollectorNativeEventStreamError.invalidState }
    }

    private func sealAdmission() {
        condition.lock()
        admissionOpen = false
        condition.unlock()
    }

    // Only one lifecycle owner calls this; no admission lock crosses a native
    // call or queue barrier. The real API's drain is nonthrowing queue.sync;
    // fault injection may report an error after the same barrier has completed.
    private func cleanResources() -> Error? {
        var failure: Error?
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { if failure == nil { failure = error } }
        }
        if let stream {
            if nativeStarted { attempt { try api.stop(stream) } }
            if scheduled {
                attempt { try api.invalidate(stream) }
                attempt { try api.drain(callbackQueue) }
            }
            api.release(stream)
        }
        stream = nil
        nativeStarted = false
        scheduled = false
        if let descriptor { api.closeRoot(descriptor) }
        descriptor = nil
        return failure
    }

    private func validatedCursor() throws -> UInt64 {
        guard let checkpoint = request.resumeCheckpoint else { return 0 }
        let bytes = checkpoint.cursor.utf8
        guard (1...20).contains(bytes.count), bytes.first != 48,
              bytes.allSatisfy({ (48...57).contains($0) }),
              let cursor = UInt64(checkpoint.cursor), cursor > 0, cursor < UInt64.max else {
            throw CollectorNativeEventStreamError.invalidCheckpoint
        }
        return cursor
    }

    private func validatedEpoch() throws -> String {
        let prefix = "fsevents-device-v1:"
        guard request.epoch.utf8.count == prefix.utf8.count + 36,
              request.epoch.hasPrefix(prefix) else { throw CollectorNativeEventStreamError.invalidEpoch }
        let suffix = String(request.epoch.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix), uuid.uuidString.utf8.elementsEqual(suffix.utf8),
              request.resumeCheckpoint.map({ $0.epoch.utf8.elementsEqual(request.epoch.utf8) }) ?? true else {
            throw CollectorNativeEventStreamError.invalidEpoch
        }
        return suffix
    }

    private func validate(_ observation: CollectorNativeRootObservation, uuid: String) throws -> String {
        guard observation.descriptorIdentity == request.binding.expectedIdentity,
              observation.routeIdentity == request.binding.expectedIdentity,
              observation.volumeDevice == request.binding.expectedIdentity.device,
              let device = Int32(exactly: observation.volumeDevice), device > 0 else {
            throw CollectorNativeEventStreamError.invalidRoot
        }
        guard let observedUUID = observation.eventDatabaseUUID,
              observedUUID.utf8.elementsEqual(uuid.utf8) else { throw CollectorNativeEventStreamError.invalidEpoch }
        let root = Array(observation.physicalRootPath.utf8)
        let mount = Array(observation.volumeMountPath.utf8)
        guard Self.safeAbsolute(root), Self.safeAbsolute(mount) else {
            throw CollectorNativeEventStreamError.invalidRoot
        }
        if root == mount { return "" }
        let prefix = mount == [47] ? mount : mount + [47]
        guard root.starts(with: prefix), root.count > prefix.count,
              let relative = String(bytes: root.dropFirst(prefix.count), encoding: .utf8) else {
            throw CollectorNativeEventStreamError.invalidRoot
        }
        return relative
    }

    private static func safeAbsolute(_ bytes: [UInt8]) -> Bool {
        guard bytes.first == 47, bytes.count <= CollectorPOSIXRootEnumerator.maximumPathBytes else { return false }
        return bytes == [47] || safeRelative(Array(bytes.dropFirst()), depth: CollectorPOSIXRootEnumerator.maximumAbsoluteComponents)
    }

    private static func safeRelative(_ bytes: [UInt8], depth: Int) -> Bool {
        guard !bytes.isEmpty, !bytes.contains(0) else { return false }
        let components = bytes.split(separator: 47, omittingEmptySubsequences: false)
        return components.count <= depth && components.allSatisfy {
            !$0.isEmpty && !$0.elementsEqual([46]) && !$0.elementsEqual([46, 46])
        }
    }

    // On the serial callback queue only. A copied closure is an entered
    // admission; external stop can seal subsequent admissions while this one
    // returns, then drain waits for the entire callback to exit.
    private func admit(_ signal: CollectorEventStreamSignal) -> Bool {
        condition.lock()
        let target = admissionOpen ? deliver : nil
        condition.unlock()
        guard let target else { return false }
        switch target(signal) {
        case .queued, .controlAccepted: return true
        case .rejectedClosed, .recoveryRequired:
            sealAdmission()
            return false
        }
    }

    private func lose(_ reason: CollectorEventGapReason) {
        condition.lock()
        let target = admissionOpen ? deliver : nil
        admissionOpen = false
        condition.unlock()
        _ = target?(.loss(reason))
    }

    private enum Decoded {
        case batch(CollectorEventBatch, UInt64)
        case history
    }

    private func receive(count: Int, paths: UnsafeRawPointer?, flags: UnsafePointer<FSEventStreamEventFlags>?,
                         ids: UnsafePointer<FSEventStreamEventId>?) {
        condition.lock()
        let open = admissionOpen
        condition.unlock()
        guard open else { return }
        // These checks MUST precede ranges, pointer arithmetic and dereferences.
        guard count >= 0 else { lose(.continuityLoss); return }
        guard count > 0 else { return }
        guard count <= budget.maxIncomingPaths else { lose(.budgetExceeded); return }
        guard count <= Int.max / MemoryLayout<UnsafeMutablePointer<CChar>?>.stride,
              count <= Int.max / MemoryLayout<FSEventStreamEventFlags>.stride,
              count <= Int.max / MemoryLayout<FSEventStreamEventId>.stride else { lose(.budgetExceeded); return }
        guard let paths, let flags, let ids else { lose(.continuityLoss); return }
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let historyFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
        let directoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        // Dropped wins even if a preceding entry has a bad path or control flag.
        for index in 0..<count where flags[index] & dropped != 0 { lose(.overflow); return }
        for index in 0..<count {
            let flag = flags[index]
            if flag & structural != 0 || flag & directoryFlag != 0 || (flag & historyFlag == 0 && flag & fileFlag == 0) {
                lose(.continuityLoss)
                return
            }
        }
        let table = paths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
        let relativeLimit = min(budget.maxPathUTF8Bytes, CollectorPOSIXRootEnumerator.maximumPathBytes)
        // Both operands have explicit small bounds, even with an Int.max budget.
        let scanLimit = rootPrefix.count + relativeLimit + 1
        var decoded: [Decoded] = []
        var pendingPaths: [String] = []
        var candidate = highWater
        var replayFinished = historyDone
        var totalBytes = 0
        func appendBatch() -> Bool {
            guard !pendingPaths.isEmpty else { return true }
            let cursor = String(candidate)
            // Both lengths are bounded by canonical epoch/finite ID validation.
            // As at coordinator admission, this bounds the next checkpoint;
            // Owner separately checks the expected-plus-next transaction budget.
            let nextSize = request.epoch.utf8.count + cursor.utf8.count
            guard nextSize <= budget.maxCheckpointUTF8Bytes else { return false }
            decoded.append(.batch(.init(nextCheckpoint: .init(epoch: request.epoch, cursor: cursor),
                                        dirtyRelativePaths: pendingPaths), candidate))
            pendingPaths = []
            return true
        }
        for index in 0..<count {
            if flags[index] & historyFlag != 0 {
                guard appendBatch() else { lose(.budgetExceeded); return }
                if !replayFinished { decoded.append(.history) }
                replayFinished = true
                continue // HistoryDone's path and ID are explicitly ignored.
            }
            let id = ids[index]
            guard id > 0, id < UInt64.max, !replayFinished || id >= candidate,
                  let path = table[index] else { lose(.continuityLoss); return }
            let length = strnlen(path, scanLimit)
            guard length < scanLimit else { lose(.budgetExceeded); return }
            let bytes = UnsafeRawBufferPointer(start: path, count: length)
            guard length > rootPrefix.count, bytes.starts(with: rootPrefix) else { lose(.continuityLoss); return }
            let relativeBytes = Array(bytes.dropFirst(rootPrefix.count))
            guard Self.safeRelative(relativeBytes, depth: CollectorPOSIXRootEnumerator.maximumRelativeDepth),
                  let relative = String(bytes: relativeBytes, encoding: .utf8) else { lose(.continuityLoss); return }
            let (absoluteBytes, pathOverflow) = request.binding.configuration.rootPath.utf8.count
                .addingReportingOverflow(relativeBytes.count + 1)
            guard !pathOverflow, absoluteBytes <= CollectorPOSIXRootEnumerator.maximumPathBytes else {
                lose(.continuityLoss)
                return
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(relativeBytes.count)
            guard !overflow, sum <= budget.maxTotalPathUTF8Bytes else { lose(.budgetExceeded); return }
            totalBytes = sum
            candidate = max(candidate, id)
            pendingPaths.append(relative)
        }
        guard appendBatch() else { lose(.budgetExceeded); return }
        // No prefix is published until every entry and every checkpoint passes.
        for item in decoded {
            switch item {
            case let .batch(batch, cursor):
                guard admit(.batch(batch)) else { return }
                highWater = cursor // A queued candidate, never a durability ACK.
            case .history:
                guard admit(.historyDone) else { return }
                historyDone = true
            }
        }
    }
}

// The only production native boundary. Neither init nor the raw C trampoline
// performs source discovery, inventory work, asynchronous dispatch, or Task work.
private final class CollectorNativeSystemAPI: CollectorNativeEventAPI {
    func openRoot(_ binding: CollectorPOSIXRootBinding) throws -> Int32 {
        let components = try CollectorPOSIXDirectoryAccess.components(binding.configuration.rootPath)
        return try CollectorPOSIXDirectoryAccess.openAbsolute(components: components).descriptor
    }

    func observeRoot(_ descriptor: Int32, binding: CollectorPOSIXRootBinding) throws -> CollectorNativeRootObservation {
        let held = try CollectorPOSIXDirectoryAccess.directoryStat(descriptor)
        let route = try CollectorPOSIXDirectoryAccess.openAbsolute(
            components: CollectorPOSIXDirectoryAccess.components(binding.configuration.rootPath))
        defer { CollectorPOSIXDirectoryAccess.close(route.descriptor) }
        let physicalRoot = try physicalPath(descriptor)
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0, held.st_dev > 0, held.st_dev == volume.f_fsid.val.0 else {
            throw CollectorNativeEventStreamError.invalidRoot
        }
        let mountPath = try withUnsafeBytes(of: &volume.f_mntonname) { try boundedString($0) }
        let mountDescriptor: Int32
        if mountPath == "/" {
            mountDescriptor = try CollectorPOSIXDirectoryAccess.openComponent("/", parent: AT_FDCWD)
        } else {
            mountDescriptor = try CollectorPOSIXDirectoryAccess.openAbsolute(
                components: CollectorPOSIXDirectoryAccess.components(mountPath)).descriptor
        }
        defer { CollectorPOSIXDirectoryAccess.close(mountDescriptor) }
        let mountInfo = try CollectorPOSIXDirectoryAccess.directoryStat(mountDescriptor)
        guard mountInfo.st_dev == held.st_dev else { throw CollectorNativeEventStreamError.invalidRoot }
        let physicalMount = try physicalPath(mountDescriptor)
        // The DB UUID identifies the event history, not the filesystem's UUID.
        let databaseUUID = FSEventsCopyUUIDForDevice(held.st_dev).map { CFUUIDCreateString(nil, $0) as String }
        return .init(descriptorIdentity: try CollectorPOSIXDirectoryAccess.identity(held),
                     routeIdentity: try CollectorPOSIXDirectoryAccess.identity(route.info),
                     physicalRootPath: physicalRoot, volumeMountPath: physicalMount,
                     volumeDevice: Int64(held.st_dev), eventDatabaseUUID: databaseUUID)
    }

    func closeRoot(_ descriptor: Int32) { CollectorPOSIXDirectoryAccess.close(descriptor) }

    private func physicalPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH_NOFIRMLINK, $0.baseAddress!) }
        guard result == 0 else { throw CollectorNativeEventStreamError.invalidRoot }
        return try buffer.withUnsafeBytes { try boundedString($0) }
    }

    private func boundedString(_ bytes: UnsafeRawBufferPointer) throws -> String {
        guard let end = bytes.firstIndex(of: 0), end > 0,
              let value = String(bytes: bytes[..<end], encoding: .utf8) else {
            throw CollectorNativeEventStreamError.invalidRoot
        }
        return value
    }

    func create(_ request: CollectorNativeEventCreateRequest,
                callback: @escaping CollectorNativeRawEventCallback) throws -> (any CollectorNativeEventHandle)? {
        let box = CollectorNativeCallbackBox(callback)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let paths = [request.volumeRelativeRoot] as CFArray
        let reference = withExtendedLifetime(box) {
            FSEventStreamCreateRelativeToDevice(nil, { _, info, count, paths, flags, ids in
                guard let info else { return }
                let box = Unmanaged<CollectorNativeCallbackBox>.fromOpaque(info).takeUnretainedValue()
                box.callback(count, UnsafeRawPointer(paths), flags, ids)
            }, &context, request.device, paths, request.sinceWhen, 0.1, request.flags)
        }
        guard let reference else { return nil }
        return CollectorNativeSystemHandle(reference: reference, box: box)
    }

    func schedule(_ stream: any CollectorNativeEventHandle, on queue: DispatchQueue) throws {
        FSEventStreamSetDispatchQueue(try handle(stream).reference, queue)
    }

    func start(_ stream: any CollectorNativeEventHandle) -> Bool {
        guard let stream = stream as? CollectorNativeSystemHandle else { return false }
        return FSEventStreamStart(stream.reference)
    }

    func stop(_ stream: any CollectorNativeEventHandle) throws { FSEventStreamStop(try handle(stream).reference) }
    func invalidate(_ stream: any CollectorNativeEventHandle) throws { FSEventStreamInvalidate(try handle(stream).reference) }
    func drain(_ queue: DispatchQueue) throws { queue.sync {} }

    func release(_ stream: any CollectorNativeEventHandle) {
        guard let stream = stream as? CollectorNativeSystemHandle else { return }
        // Invalidate while still scheduled, drain, then release the stream before
        // dropping its callback context. Never detach with SetDispatchQueue(nil).
        withExtendedLifetime(stream.box) { FSEventStreamRelease(stream.reference) }
    }

    private func handle(_ stream: any CollectorNativeEventHandle) throws -> CollectorNativeSystemHandle {
        guard let stream = stream as? CollectorNativeSystemHandle else { throw CollectorNativeEventStreamError.invalidState }
        return stream
    }
}

private final class CollectorNativeCallbackBox {
    let callback: CollectorNativeRawEventCallback
    init(_ callback: @escaping CollectorNativeRawEventCallback) { self.callback = callback }
}

private final class CollectorNativeSystemHandle: CollectorNativeEventHandle {
    let reference: FSEventStreamRef
    let box: CollectorNativeCallbackBox
    init(reference: FSEventStreamRef, box: CollectorNativeCallbackBox) {
        self.reference = reference
        self.box = box
    }
}

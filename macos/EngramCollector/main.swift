import Darwin
import Dispatch
import Foundation
import EngramCollectorCore

private struct Options {
    let settings: URL
    let credentials: URL?
    let once: Bool
    let initialize: Bool
    let reconcileNativeEpoch: Bool
    let dryRun: Bool
    let spoolGC: Bool
    let spoolRoot: URL?
    let centralEvidence: URL?
    let previewBytes: Int64
    let previewObjects: Int
    let gcAction: String?
    let gcRunID: String?
    let approvalFile: URL?
    let approvedSHA256: String?

    init(arguments: [String]) throws {
        var settings: String?
        var credentials: String?
        var once = false
        var initialize = false
        var reconcileNativeEpoch = false
        var dryRun = false
        var spoolGC = false
        var spoolRoot: String?
        var centralEvidence: String?
        var previewBytes: Int64?
        var previewObjects: Int?
        var gcAction: String?
        var gcRunID: String?
        var approvalFile: String?
        var approvedSHA256: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--settings", "--credentials-file", "--spool-root", "--central-evidence", "--approval-file":
                guard index + 1 < arguments.count else { throw ArgumentsError.invalid }
                let value = arguments[index + 1]
                guard Self.validAbsolutePath(value) else { throw ArgumentsError.invalid }
                if argument == "--settings" {
                    guard settings == nil else { throw ArgumentsError.invalid }
                    settings = value
                } else if argument == "--credentials-file" {
                    guard credentials == nil else { throw ArgumentsError.invalid }
                    credentials = value
                } else if argument == "--spool-root" {
                    guard spoolRoot == nil else { throw ArgumentsError.invalid }
                    spoolRoot = value
                } else if argument == "--approval-file" {
                    guard approvalFile == nil else { throw ArgumentsError.invalid }
                    approvalFile = value
                } else {
                    guard centralEvidence == nil else { throw ArgumentsError.invalid }
                    centralEvidence = value
                }
                index += 2
            case "--apply":
                guard gcAction == nil else { throw ArgumentsError.invalid }
                gcAction = "apply"; index += 1
            case "--restore", "--finalize":
                guard gcAction == nil, index + 1 < arguments.count, UUID(uuidString: arguments[index + 1]) != nil else { throw ArgumentsError.invalid }
                gcAction = String(argument.dropFirst(2)); gcRunID = arguments[index + 1]; index += 2
            case "--approve-sha256":
                guard approvedSHA256 == nil, index + 1 < arguments.count else { throw ArgumentsError.invalid }
                let value = arguments[index + 1]
                guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ArgumentsError.invalid }
                approvedSHA256 = value; index += 2
            case "--spool-gc":
                guard !spoolGC else { throw ArgumentsError.invalid }
                spoolGC = true
                index += 1
            case "--max-preview-bytes", "--max-preview-objects":
                guard index + 1 < arguments.count, let value = Int64(arguments[index + 1]), value >= 0 else { throw ArgumentsError.invalid }
                if argument == "--max-preview-bytes" {
                    guard previewBytes == nil else { throw ArgumentsError.invalid }
                    previewBytes = value
                } else {
                    guard previewObjects == nil, let count = Int(exactly: value) else { throw ArgumentsError.invalid }
                    previewObjects = count
                }
                index += 2
            case "--once":
                guard !once else { throw ArgumentsError.invalid }
                once = true
                index += 1
            case "--initialize":
                guard !initialize else { throw ArgumentsError.invalid }
                initialize = true
                index += 1
            case "--reconcile-native-epoch":
                guard !reconcileNativeEpoch else { throw ArgumentsError.invalid }
                reconcileNativeEpoch = true
                index += 1
            case "--dry-run":
                guard !dryRun else { throw ArgumentsError.invalid }
                dryRun = true
                index += 1
            default:
                throw ArgumentsError.invalid
            }
        }
        // Operator modes never run a collection cycle. Preview also rejects
        // credentials; --dry-run is valid only for reconciliation or preview.
        guard let input = settings ?? spoolRoot,
              !spoolGC || (!once && !initialize && !reconcileNativeEpoch && credentials == nil && (settings == nil) != (spoolRoot == nil)),
              spoolGC || (spoolRoot == nil && centralEvidence == nil && previewBytes == nil && previewObjects == nil),
              !initialize || (!once && credentials == nil && !reconcileNativeEpoch),
              !reconcileNativeEpoch || (!once && credentials == nil),
              !dryRun || reconcileNativeEpoch || spoolGC else { throw ArgumentsError.invalid }
        if let action = gcAction {
            guard spoolGC, settings != nil, spoolRoot == nil, !dryRun,
                  centralEvidence == nil, previewBytes == nil, previewObjects == nil,
                  action == "restore" ? (approvalFile == nil && approvedSHA256 == nil) : (approvalFile != nil && approvedSHA256 != nil) else { throw ArgumentsError.invalid }
        } else {
            guard approvalFile == nil, approvedSHA256 == nil else { throw ArgumentsError.invalid }
        }
        self.gcAction = gcAction
        self.gcRunID = gcRunID
        self.approvalFile = approvalFile.map { URL(fileURLWithPath: $0) }
        self.approvedSHA256 = approvedSHA256
        self.settings = URL(fileURLWithPath: input)
        self.credentials = credentials.map { URL(fileURLWithPath: $0) }
        self.once = once
        self.initialize = initialize
        self.reconcileNativeEpoch = reconcileNativeEpoch
        self.dryRun = dryRun
        self.spoolGC = spoolGC
        self.spoolRoot = spoolRoot.map { URL(fileURLWithPath: $0) }
        self.centralEvidence = centralEvidence.map { URL(fileURLWithPath: $0) }
        self.previewBytes = previewBytes ?? 256 * 1024 * 1024
        self.previewObjects = previewObjects ?? 128
    }

    static func validAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.utf8.contains(0) else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

private enum ArgumentsError: Error { case invalid }

private let usage = """
usage: EngramCollector --settings ABS [--credentials-file ABS] [--once]
       EngramCollector --settings ABS --initialize
       EngramCollector --settings ABS --reconcile-native-epoch [--dry-run]
       EngramCollector --initialize-identity ABS
       EngramCollector --spool-gc (--spool-root ABS | --settings ABS) [--central-evidence ABS]
           [--max-preview-bytes N] [--max-preview-objects N] [--dry-run]
       EngramCollector --settings ABS --spool-gc --apply --approval-file ABS --approve-sha256 HASH
       EngramCollector --settings ABS --spool-gc --finalize RUN --approval-file ABS --approve-sha256 HASH
       EngramCollector --settings ABS --spool-gc --restore RUN
       EngramCollector --help
--once runs one bounded cycle; it does not wait for bootstrap or replica acknowledgements.
--initialize creates a new private spool using the configured existing machine identity; it never starts collection.
--reconcile-native-epoch is the operator action for a changed FSEvents epoch (stderr line
  "source roots suspended for native epoch change"): with the collector stopped it records each
  affected root's transition, clears its stored event checkpoint and forces a full walk; --dry-run only reports.
--initialize-identity creates a new identity catalog only; use only after confirming this host has no existing identity.
--spool-gc defaults to a read-only preview, with no locks, credentials, network or writes.
  Preview potential bytes remain conditional; actionableBytes is always zero.
  --apply quarantines an approved batch; --finalize separately unlinks after the hold and fresh proof.
  Both require private evidence bound by --approve-sha256. --restore needs no proof or token.
  Mutating modes require a stopped collector and acquire its existing lock; they never stop services.
  Quarantine does not free volume space. These modes never discover credentials or contact replicas.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print(usage)
    exit(0)
}

// First-machine provisioning is deliberately separate from runtime settings,
// credentials, spool initialization, and collection. Existing hosts borrow their
// catalog through --initialize instead of allocating another identity.
if arguments.first == "--initialize-identity" {
    guard arguments.count == 2, Options.validAbsolutePath(arguments[1]) else {
        FileHandle.standardError.write(Data("engram-collector: invalid arguments\n".utf8))
        exit(64)
    }
    do {
        _ = try CollectorIdentityInitializer.create(at: URL(fileURLWithPath: arguments[1]))
        print("engram-collector: identity initialized")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("engram-collector: identity initialization failed\n".utf8))
        exit(70)
    }
}

private let options: Options
do { options = try Options(arguments: arguments) }
catch {
    FileHandle.standardError.write(Data("engram-collector: invalid arguments\n".utf8))
    exit(64)
}

// Install every disposition and handler before any owned producer can start.
private let termination = TerminationSignals()
private let collectorTask = Task {
    let code = await runCollector(options)
    exit(code)
}
termination.attach(collectorTask)
withExtendedLifetime(termination) { dispatchMain() }

private func runCollector(_ options: Options) async -> Int32 {
    if options.spoolGC {
        if let action = options.gcAction {
            do {
                let bytes = try CollectorSpoolGCOperator.run(settingsURL: options.settings, action: action,
                    runID: options.gcRunID, approvalURL: options.approvalFile, approvedSHA256: options.approvedSHA256)
                print(String(decoding: bytes, as: UTF8.self))
                return 0
            } catch {
                let reason = (error as? CollectorSpoolGCError)?.rawValue
                    ?? "operatorInputUnavailable"
                FileHandle.standardError.write(Data("engram-collector: spool GC failed: \(reason)\n".utf8))
                return 70
            }
        }
        do {
            let root = try options.spoolRoot ?? CollectorSpoolGCPreview.spoolRoot(settingsURL: options.settings)
            let report = try CollectorSpoolGCPreview.run(spoolRoot: root, centralEvidence: options.centralEvidence,
                maxBytes: options.previewBytes, maxObjects: options.previewObjects)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return 0
        } catch {
            // Never print SQL, paths, evidence contents or configuration payloads.
            let reason = (error as? CollectorSpoolGCPreview.Failure)?.rawValue ?? "readOnlyInputUnavailable"
            FileHandle.standardError.write(Data("engram-collector: spool preview failed: \(reason)\n".utf8))
            return 70
        }
    }
    if options.initialize {
        do {
            try CollectorRuntime.initialize(settingsURL: options.settings)
            print("engram-collector: initialized")
            return 0
        } catch {
            FileHandle.standardError.write(Data("engram-collector: initialization failed\n".utf8))
            return 70
        }
    }
    if options.reconcileNativeEpoch {
        do {
            let report = try CollectorRuntime.reconcileNativeEpoch(settingsURL: options.settings, dryRun: options.dryRun)
            let roots: [[String: Any]] = report.roots.map { root in
                var values: [String: Any] = ["rootID": root.rootID, "source": root.source, "rootPath": root.rootPath,
                    "outcome": root.outcome.rawValue, "storedEpoch": root.storedEpoch ?? NSNull(),
                    "liveEpoch": root.liveEpoch ?? NSNull(), "requestedRevision": root.requestedRevision.map { $0 as Any } ?? NSNull()]
                if let failure = root.failure { values["failure"] = failure }
                return values
            }
            let values: [String: Any] = ["dryRun": report.dryRun, "affectedRoots": report.affectedRoots, "roots": roots]
            print(String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self))
            return 0
        } catch {
            let reason = CollectorRuntime.failureReason(error)
            FileHandle.standardError.write(Data("engram-collector: native epoch reconcile failed: \(reason)\n".utf8))
            return 70
        }
    }
    let credentials = ExplicitCredentialFile(url: options.credentials)
    var runtime: CollectorRuntime?
    var failure: Error?
    var output: String?
    do {
        runtime = try CollectorRuntime.open(settingsURL: options.settings, secretLoader: { reference in
            try credentials.token(for: reference)
        })
        if let runtime {
            if options.once {
                let cycle = try await runtime.runOnce(now: Int64(Date().timeIntervalSince1970))
                var values: [String: Any] = ["scannedEntries": cycle.scannedEntries, "captured": cycle.captured,
                    "recovered": cycle.recovered, "acknowledgedHQ": cycle.acknowledgedHQ,
                    "acknowledgedM1": cycle.acknowledgedM1, "deferred": cycle.deferred]
                switch cycle.diskAdmission {
                case .notEvaluated:
                    values["diskAdmission"] = ["state": "notEvaluated"]
                case .observed(let threshold, let inventory, let capture):
                    values["diskAdmission"] = ["state": "observed", "minimumFreeDiskBytes": threshold,
                        "inventoryMinimumAvailableBytes": inventory.map { $0 as Any } ?? NSNull(),
                        "captureMinimumAvailableBytes": capture.map { $0 as Any } ?? NSNull()]
                }
                output = String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
            } else {
                try await runtime.start()
                print("engram-collector: running")
                try await runtime.waitUntilStopped()
            }
        } else { output = "engram-collector: disabled" }
    } catch is CancellationError {
        // Signals cancel the same task whose runtime is joined below.
    } catch { failure = error }
    do { try await runtime?.stop() }
    catch { if failure == nil { failure = error } }
    // stop may rethrow a producer failure after successful cleanup. Keep the
    // classification bounded without incorrectly claiming a close failure. The
    // line names the first failure by type and case only (no payload), so an
    // operator can tell exit causes apart.
    if let failure {
        let reason = CollectorRuntime.failureReason(failure)
        FileHandle.standardError.write(Data("engram-collector: runtime failed: \(reason)\n".utf8))
        return 70
    }
    if let output { print(output) }
    return 0
}

private final class TerminationSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var task: Task<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    init() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.request() }
            sources.append(source)
            source.resume()
        }
    }

    func attach(_ task: Task<Void, Never>) {
        let cancel = lock.withLock { self.task = task; return requested }
        if cancel { task.cancel() }
    }

    private func request() {
        let current = lock.withLock { requested = true; return task }
        current?.cancel()
    }
}

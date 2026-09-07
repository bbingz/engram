import Darwin
import Dispatch
import Foundation
import EngramCollectorCore

private struct Options {
    let settings: URL
    let credentials: URL?
    let once: Bool

    init(arguments: [String]) throws {
        var settings: String?
        var credentials: String?
        var once = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--settings", "--credentials-file":
                guard index + 1 < arguments.count else { throw ArgumentsError.invalid }
                let value = arguments[index + 1]
                guard Self.validAbsolutePath(value) else { throw ArgumentsError.invalid }
                if argument == "--settings" {
                    guard settings == nil else { throw ArgumentsError.invalid }
                    settings = value
                } else {
                    guard credentials == nil else { throw ArgumentsError.invalid }
                    credentials = value
                }
                index += 2
            case "--once":
                guard !once else { throw ArgumentsError.invalid }
                once = true
                index += 1
            default:
                throw ArgumentsError.invalid
            }
        }
        guard let settings else { throw ArgumentsError.invalid }
        self.settings = URL(fileURLWithPath: settings)
        self.credentials = credentials.map { URL(fileURLWithPath: $0) }
        self.once = once
    }

    private static func validAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.utf8.contains(0) else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

private enum ArgumentsError: Error { case invalid }

private let usage = """
usage: EngramCollector --settings ABS [--credentials-file ABS] [--once]
       EngramCollector --help
--once runs one bounded cycle; it does not wait for bootstrap or replica acknowledgements.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print(usage)
    exit(0)
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
    let credentials = ExplicitCredentialFile(url: options.credentials)
    var runtime: CollectorRuntime?
    var failed = false
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
    } catch { failed = true }
    do { try await runtime?.stop() }
    catch { failed = true }
    // stop may rethrow a producer failure after successful cleanup. Keep the
    // classification bounded without incorrectly claiming a close failure.
    if failed {
        FileHandle.standardError.write(Data("engram-collector: runtime failed\n".utf8))
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

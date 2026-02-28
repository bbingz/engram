// macos/CodingMemory/Core/IndexerProcess.swift
import Foundation
import Combine

struct DaemonEvent: Decodable {
    let event: String        // "ready" | "indexed" | "error"
    let indexed: Int?
    let total: Int?
    let message: String?
}

@MainActor
class IndexerProcess: ObservableObject {
    enum Status {
        case stopped
        case starting
        case running(total: Int)
        case error(String)

        var displayString: String {
            switch self {
            case .stopped:          return "Stopped"
            case .starting:         return "Starting..."
            case .running(let n):   return "\(n) sessions indexed"
            case .error(let msg):   return "Error: \(msg)"
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published var status: Status = .stopped
    @Published var totalSessions: Int = 0

    private var process: Process?
    private var stdoutPipe: Pipe?

    func start(nodePath: String, scriptPath: String, dbPath: String? = nil) {
        guard process == nil else { return }
        status = .starting

        // Kill any orphaned indexer processes from previous app runs (e.g. Xcode SIGKILL)
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-f", "node.*\(URL(fileURLWithPath: scriptPath).lastPathComponent)"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError  = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        var args = [scriptPath]
        if let dbPath { args.append(dbPath) }
        proc.arguments = args

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = Pipe()   // discard stderr

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.process = nil
                self?.stdoutPipe = nil
                self?.status = .stopped
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let event = try? JSONDecoder().decode(DaemonEvent.self, from: Data(line.utf8)) else { continue }
                Task { @MainActor [weak self] in self?.handleEvent(event) }
            }
        }

        process  = proc
        stdoutPipe = outPipe

        do {
            try proc.run()
        } catch {
            status = .error(error.localizedDescription)
            process = nil
            stdoutPipe = nil
        }
    }

    func stop() {
        process?.terminate()
        process    = nil
        stdoutPipe = nil
        status = .stopped
    }

    private func handleEvent(_ event: DaemonEvent) {
        switch event.event {
        case "ready":
            let n = event.total ?? 0
            totalSessions = n
            status = .running(total: n)
        case "indexed":
            let n = event.total ?? totalSessions
            totalSessions = n
            status = .running(total: n)
        case "error":
            status = .error(event.message ?? "Unknown error")
        default:
            break
        }
    }
}

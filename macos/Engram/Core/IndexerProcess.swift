// macos/Engram/Core/IndexerProcess.swift
import Foundation
import Combine

struct DaemonEvent: Decodable {
    let event: String        // "ready" | "indexed" | "error" | "web_ready" | "summary_generated" | "db_maintenance"
    let indexed: Int?
    let total: Int?
    let message: String?
    let sessionId: String?
    let summary: String?
    let port: Int?
    let host: String?
    let action: String?      // db_maintenance: "vacuum" | "dedup"
    let removed: Int?         // db_maintenance dedup: count of removed duplicates
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
            case .stopped:          return String(localized: "Stopped")
            case .starting:         return String(localized: "Starting...")
            case .running(let n):   return String(localized: "\(n) sessions indexed")
            case .error(let msg):   return String(localized: "Error: \(msg)")
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    struct UsageItem: Identifiable {
        var id: String { "\(source)_\(metric)" }
        let source: String
        let metric: String
        let value: Double   // 0-100
        let resetAt: String?
    }

    @Published var status: Status = .stopped
    @Published var totalSessions: Int = 0
    @Published var lastSummarySessionId: String?
    @Published var port: Int?
    @Published var usageData: [UsageItem] = []

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

        // Pass Keychain values via environment variables so the Node daemon
        // doesn't need to call `security` CLI (which prompts for authorization)
        var env = ProcessInfo.processInfo.environment
        env["ENGRAM_DAEMON"] = "1"  // Signal to Node that it's launched from Swift app
        for key in ["vikingApiKey", "aiApiKey", "titleApiKey"] {
            if let value = KeychainHelper.get(key), !value.isEmpty {
                env["ENGRAM_KEYCHAIN_\(key)"] = value
            }
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        // Forward daemon stderr to os_log for diagnostics
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            EngramLogger.error(text, module: .daemon)
        }

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
                let lineData = Data(line.utf8)
                // Handle usage events via raw JSON (data field is an array, not in DaemonEvent)
                if let raw = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let eventName = raw["event"] as? String,
                   eventName == "usage" {
                    let dataArray = raw["data"] as? [[String: Any]] ?? []
                    Task { @MainActor [weak self] in self?.handleUsageEvent(dataArray) }
                    continue
                }
                guard let event = try? JSONDecoder().decode(DaemonEvent.self, from: lineData) else { continue }
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
        case "ready", "indexed", "rescan", "sync_complete", "watcher_indexed":
            if let n = event.total {
                totalSessions = n
                status = .running(total: n)
            }
        case "web_ready":
            port = event.port
        case "summary_generated":
            if let n = event.total {
                totalSessions = n
                status = .running(total: n)
            }
            lastSummarySessionId = event.sessionId
        case "error":
            status = .error(event.message ?? "Unknown error")
        default:
            break
        }
    }

    private func handleUsageEvent(_ dataArray: [[String: Any]]) {
        usageData = dataArray.compactMap { item in
            guard let source = item["source"] as? String,
                  let metric = item["metric"] as? String,
                  let value = item["value"] as? Double else { return nil }
            return UsageItem(source: source, metric: metric, value: value, resetAt: item["resetAt"] as? String)
        }
    }
}

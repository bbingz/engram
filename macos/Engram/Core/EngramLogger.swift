// macos/Engram/Core/EngramLogger.swift
import Foundation
import os

enum LogModule: String, CaseIterable {
    case daemon, database, ui, mcp, indexer, network
}

struct EngramLogger {
    private static let subsystem = "com.engram.app"
    private static let loggers: [LogModule: os.Logger] = {
        var dict: [LogModule: os.Logger] = [:]
        for module in LogModule.allCases {
            dict[module] = os.Logger(subsystem: subsystem, category: module.rawValue)
        }
        return dict
    }()

    private static func logger(for module: LogModule) -> os.Logger {
        loggers[module]!
    }

    static func info(_ message: String, module: LogModule) {
        logger(for: module).info("\(message, privacy: .public)")
    }

    static func warn(_ message: String, module: LogModule) {
        logger(for: module).warning("\(message, privacy: .public)")
        forwardToDaemon(level: "warn", module: module, message: message)
    }

    static func error(_ message: String, module: LogModule, error: Error? = nil) {
        let msg = error.map { "\(message): \($0.localizedDescription)" } ?? message
        logger(for: module).error("\(msg, privacy: .public)")
        forwardToDaemon(level: "error", module: module, message: msg)
    }

    static func debug(_ message: String, module: LogModule) {
        logger(for: module).debug("\(message, privacy: .public)")
    }

    // MARK: - Daemon Forwarding (fire-and-forget)

    private static func forwardToDaemon(level: String, module: LogModule, message: String, traceId: String? = nil) {
        guard module != .daemon, module != .network else { return }

        Task.detached {
            guard let url = URL(string: "http://127.0.0.1:3457/api/log") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let requestTraceId = traceId ?? UUID().uuidString
            request.setValue(requestTraceId, forHTTPHeaderField: "X-Trace-Id")
            request.timeoutInterval = 2
            var body: [String: Any] = ["level": level, "module": module.rawValue, "message": message]
            if let traceId { body["traceId"] = traceId }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}

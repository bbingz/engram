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

    // Messages can carry paths, session ids, and error text, so they stay
    // `privacy: .private` to avoid leaking them into the system log readable by
    // non-entitled processes. Making the gated Observability log viewer readable
    // is deferred: the correct follow-up is a sanitized in-process buffer, NOT
    // blanket `.public` here.
    static func info(_ message: String, module: LogModule) {
        logger(for: module).info("\(message, privacy: .private)")
    }

    static func warn(_ message: String, module: LogModule) {
        logger(for: module).warning("\(message, privacy: .private)")
    }

    static func error(_ message: String, module: LogModule, error: Error? = nil) {
        let msg = error.map { "\(message): \($0.localizedDescription)" } ?? message
        logger(for: module).error("\(msg, privacy: .private)")
    }

    static func debug(_ message: String, module: LogModule) {
        logger(for: module).debug("\(message, privacy: .private)")
    }

}

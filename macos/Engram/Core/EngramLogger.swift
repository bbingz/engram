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
    }

    static func error(_ message: String, module: LogModule, error: Error? = nil) {
        let msg = error.map { "\(message): \($0.localizedDescription)" } ?? message
        logger(for: module).error("\(msg, privacy: .public)")
    }

    static func debug(_ message: String, module: LogModule) {
        logger(for: module).debug("\(message, privacy: .public)")
    }

}

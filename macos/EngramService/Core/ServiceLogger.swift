// macos/EngramService/Core/ServiceLogger.swift
import Foundation
import os

public enum ServiceLogCategory: String, CaseIterable {
    case runner
    case ipc
    case checkpoint
    case writer
    case reader
}

public enum ServiceLogger {
    private static let subsystem = "com.engram.service"
    private static let loggers: [ServiceLogCategory: os.Logger] = {
        var dict: [ServiceLogCategory: os.Logger] = [:]
        for category in ServiceLogCategory.allCases {
            dict[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
        }
        return dict
    }()

    private static func logger(for category: ServiceLogCategory) -> os.Logger {
        loggers[category]!
    }

    public static func debug(_ message: String, category: ServiceLogCategory) {
        logger(for: category).debug("\(message, privacy: .public)")
    }

    public static func info(_ message: String, category: ServiceLogCategory) {
        logger(for: category).info("\(message, privacy: .public)")
    }

    public static func notice(_ message: String, category: ServiceLogCategory) {
        logger(for: category).notice("\(message, privacy: .public)")
    }

    public static func warn(_ message: String, category: ServiceLogCategory) {
        logger(for: category).warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String, category: ServiceLogCategory, error: Error? = nil) {
        let msg = error.map { "\(message): \($0.localizedDescription)" } ?? message
        logger(for: category).error("\(msg, privacy: .public)")
    }
}

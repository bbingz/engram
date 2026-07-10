// macos/EngramService/Core/ServiceLogger.swift
import Foundation
import os

public enum ServiceLogCategory: String, CaseIterable {
    case runner
    case ipc
    case checkpoint
    case writer
    case reader
    case ai
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

    // Process-wide sink for a SANITIZED copy of each line. nil by default, so in
    // tests (and any process that doesn't install it) behavior is exactly the
    // os_log path below. `EngramServiceRunner` installs it once at startup. The
    // ring sanitizes internally; the os_log call stays `privacy: .private`.
    nonisolated(unsafe) private static var ring: ServiceLogRing?

    /// Install the in-process log ring. Call once at service startup before the
    /// server starts. Idempotent set; not meant to be swapped at runtime.
    /// `internal` (not `public`): `ServiceLogRing` is an internal type and the
    /// only caller is `EngramServiceRunner` in this same module.
    static func installRing(_ ring: ServiceLogRing) {
        self.ring = ring
    }

    /// Scoped test seam for the process-wide sink. Production installs once at
    /// startup; tests must restore the previous sink when they finish.
    @discardableResult
    static func replaceRingForTests(_ newRing: ServiceLogRing?) -> ServiceLogRing? {
        let previous = ring
        ring = newRing
        return previous
    }

    private static func logger(for category: ServiceLogCategory) -> os.Logger {
        loggers[category]!
    }

    private static func tee(level: String, category: ServiceLogCategory, message: String) {
        guard let ring else { return }
        Task { await ring.record(level: level, category: category.rawValue, message: message) }
    }

    // Messages can carry project-migration src/dst paths, session ids, error
    // text, and socket paths, so the os_log call stays `privacy: .private` to
    // avoid leaking them into the system log readable by non-entitled processes.
    // The gated Observability log viewer is made readable NOT by going `.public`
    // here, but by teeing a SANITIZED copy into the in-process `ServiceLogRing`
    // (see `tee`), which redacts paths/ids/emails/error tails before storage.
    public static func debug(_ message: String, category: ServiceLogCategory) {
        logger(for: category).debug("\(message, privacy: .private)")
        tee(level: "debug", category: category, message: message)
    }

    public static func info(_ message: String, category: ServiceLogCategory) {
        logger(for: category).info("\(message, privacy: .private)")
        tee(level: "info", category: category, message: message)
    }

    public static func notice(_ message: String, category: ServiceLogCategory) {
        logger(for: category).notice("\(message, privacy: .private)")
        tee(level: "info", category: category, message: message)
    }

    public static func warn(_ message: String, category: ServiceLogCategory) {
        logger(for: category).warning("\(message, privacy: .private)")
        tee(level: "error", category: category, message: message)
    }

    public static func error(_ message: String, category: ServiceLogCategory, error: Error? = nil) {
        let msg = error.map { "\(message): \($0.localizedDescription)" } ?? message
        logger(for: category).error("\(msg, privacy: .private)")
        tee(level: "error", category: category, message: msg)
    }
}

// macos/Engram/Core/AppEnvironment.swift
import Foundation

struct AppEnvironment {
    let dbPath: String
    let daemonPort: Int
    let autoStartDaemon: Bool
    let networkEnabled: Bool
    let fixedDate: Date?
    let popoverStandalone: Bool
    let windowSize: NSSize?
    let mockDaemon: Bool

    static let production = AppEnvironment(
        dbPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/index.sqlite").path,
        daemonPort: 3457, // matches DaemonClient default
        autoStartDaemon: true,
        networkEnabled: true,
        fixedDate: nil,
        popoverStandalone: false,
        windowSize: nil,
        mockDaemon: false
    )

    static func test(fixturePath: String) -> AppEnvironment {
        AppEnvironment(
            dbPath: fixturePath,
            daemonPort: 0, // no real daemon
            autoStartDaemon: false,
            networkEnabled: false,
            fixedDate: Date(timeIntervalSince1970: 1742601600), // 2025-03-22 fixed
            popoverStandalone: false,
            windowSize: nil,
            mockDaemon: false
        )
    }

    static func fromCommandLine() -> AppEnvironment {
        // Detect XCTest environment (TEST_HOST loads tests into app process)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return .test(fixturePath: "")
        }
        let args = CommandLine.arguments
        if args.contains("--test-mode") {
            let fixturePath = args.firstIndex(of: "--fixture-db")
                .flatMap { idx in args.indices.contains(idx + 1) ? args[idx + 1] : nil }
                ?? Bundle.main.path(forResource: "test-index", ofType: "sqlite", inDirectory: "Fixtures")
                ?? ""

            // Parse --popover-standalone
            let popoverStandalone = args.contains("--popover-standalone")

            // Parse --mock-daemon
            let mockDaemon = args.contains("--mock-daemon")

            // Parse --fixed-date (override default)
            var fixedDate = Date(timeIntervalSince1970: 1742601600) // existing default
            if let idx = args.firstIndex(of: "--fixed-date"),
               args.indices.contains(idx + 1) {
                let fmt = ISO8601DateFormatter()
                fixedDate = fmt.date(from: args[idx + 1]) ?? fixedDate
            }

            // Parse --window-size WIDTHxHEIGHT
            var windowSize: NSSize? = nil
            if let idx = args.firstIndex(of: "--window-size"),
               args.indices.contains(idx + 1) {
                let parts = args[idx + 1].split(separator: "x")
                if parts.count == 2,
                   let w = Int(parts[0]), let h = Int(parts[1]) {
                    windowSize = NSSize(width: w, height: h)
                }
            }

            return AppEnvironment(
                dbPath: fixturePath,
                daemonPort: 0,
                autoStartDaemon: false,
                networkEnabled: false,
                fixedDate: fixedDate,
                popoverStandalone: popoverStandalone,
                windowSize: windowSize,
                mockDaemon: mockDaemon
            )
        }
        if let dataDir = args.firstIndex(of: "--data-dir")
            .flatMap({ idx in args.indices.contains(idx + 1) ? args[idx + 1] : nil }) {
            return AppEnvironment(
                dbPath: "\(dataDir)/index.sqlite",
                daemonPort: AppEnvironment.production.daemonPort,
                autoStartDaemon: AppEnvironment.production.autoStartDaemon,
                networkEnabled: AppEnvironment.production.networkEnabled,
                fixedDate: nil,
                popoverStandalone: false,
                windowSize: nil,
                mockDaemon: false
            )
        }
        return .production
    }
}

// macos/Engram/Core/AppEnvironment.swift
import Foundation

struct AppEnvironment {
    let dbPath: String
    let daemonPort: Int
    let autoStartDaemon: Bool
    let networkEnabled: Bool
    let fixedDate: Date?

    static let production = AppEnvironment(
        dbPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/index.sqlite").path,
        daemonPort: 3457, // matches DaemonClient default
        autoStartDaemon: true,
        networkEnabled: true,
        fixedDate: nil
    )

    static func test(fixturePath: String) -> AppEnvironment {
        AppEnvironment(
            dbPath: fixturePath,
            daemonPort: 0, // no real daemon
            autoStartDaemon: false,
            networkEnabled: false,
            fixedDate: Date(timeIntervalSince1970: 1742601600) // 2025-03-22 fixed
        )
    }

    static func fromCommandLine() -> AppEnvironment {
        let args = CommandLine.arguments
        if args.contains("--test-mode") {
            let fixturePath = args.firstIndex(of: "--fixture-db")
                .flatMap { idx in args.indices.contains(idx + 1) ? args[idx + 1] : nil }
                ?? Bundle.main.path(forResource: "test-index", ofType: "sqlite", inDirectory: "Fixtures")
                ?? ""
            return .test(fixturePath: fixturePath)
        }
        if let dataDir = args.firstIndex(of: "--data-dir")
            .flatMap({ idx in args.indices.contains(idx + 1) ? args[idx + 1] : nil }) {
            return AppEnvironment(
                dbPath: "\(dataDir)/index.sqlite",
                daemonPort: AppEnvironment.production.daemonPort,
                autoStartDaemon: AppEnvironment.production.autoStartDaemon,
                networkEnabled: AppEnvironment.production.networkEnabled,
                fixedDate: nil
            )
        }
        return .production
    }
}

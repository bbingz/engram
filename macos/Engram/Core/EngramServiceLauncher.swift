import Foundation

struct EngramServiceLaunchConfiguration: Equatable {
    let executablePath: String
    let socketPath: String
    let databasePath: String
    let foreground: Bool

    static func `default`(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        databasePath: String,
        bundle: Bundle = .main
    ) -> EngramServiceLaunchConfiguration {
        let helperURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("EngramService")
        let socketPath = UnixSocketEngramServiceTransport.defaultSocketPath(homeDirectory: homeDirectory)
        return EngramServiceLaunchConfiguration(
            executablePath: helperURL.path,
            socketPath: socketPath,
            databasePath: databasePath,
            foreground: false
        )
    }
}

@MainActor
final class EngramServiceLauncher {
    private var process: Process?

    nonisolated static func arguments(for configuration: EngramServiceLaunchConfiguration) -> [String] {
        var arguments = [
            "--service-socket", configuration.socketPath,
            "--database-path", configuration.databasePath
        ]
        if configuration.foreground {
            arguments.append("--foreground")
        }
        return arguments
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(configuration: EngramServiceLaunchConfiguration) throws {
        guard process?.isRunning != true else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: configuration.executablePath)
        proc.arguments = Self.arguments(for: configuration)
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        process = proc
    }

    func stopIfOwned() {
        process?.terminate()
        process = nil
    }
}

import Foundation

private func argumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(arguments.index(after: index)) else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}

public enum EngramServiceRunner {
    public static func run(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let socketPath = argumentValue(after: "--service-socket", in: arguments)
            ?? environment["ENGRAM_SERVICE_SOCKET"]
            ?? UnixSocketEngramServiceTransport.defaultSocketPath()
        let databasePath = argumentValue(after: "--database-path", in: arguments)
            ?? FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".engram", isDirectory: true)
                .appendingPathComponent("index.sqlite")
                .path

        let defaultSocketPath = UnixSocketEngramServiceTransport.defaultSocketPath()
        let runtimeDirectory: URL
        if socketPath == defaultSocketPath {
            runtimeDirectory = try UnixSocketEngramServiceTransport.secureRuntimeDirectory()
        } else {
            let socketURL = URL(fileURLWithPath: socketPath)
            runtimeDirectory = socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let gate = try ServiceWriterGate(databasePath: databasePath, runtimeDirectory: runtimeDirectory)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            readProvider: SQLiteEngramServiceReadProvider(databasePath: databasePath)
        )
        let server = UnixSocketServiceServer(socketPath: socketPath) { request in
            await handler.handle(request)
        }
        try server.start()
        let checkpointTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                do {
                    try await gate.checkpointWal()
                    print(#"{"event":"checkpoint","mode":"PASSIVE","ok":true}"#)
                    fflush(stdout)
                } catch {
                    print(#"{"event":"checkpoint","mode":"PASSIVE","ok":false,"error":"\#(error.localizedDescription)"}"#)
                    fflush(stdout)
                }
            }
        }

        print(#"{"event":"ready","socket":"\#(socketPath)"}"#)
        fflush(stdout)

        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        checkpointTask.cancel()
        server.stop()
    }
}

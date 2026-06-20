import Foundation
import EngramRemoteServerCore

// `EngramRemoteServer keygen` prints a fresh base64 at-rest key for first setup.
if CommandLine.arguments.contains("keygen") {
    print(EngramRemoteServerConfig.generateAtRestKeyBase64())
    exit(0)
}

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

do {
    let config = try EngramRemoteServerConfig.fromEnvironment()
    let app = try EngramRemoteServerApp(config: config)
    stderr("engram-remote listening on \(config.host):\(config.port) store=\(config.storeRoot.path)")
    try await app.run()
} catch {
    stderr("engram-remote fatal: \(error)")
    exit(1)
}

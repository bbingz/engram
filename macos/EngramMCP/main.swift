import Foundation

private func writeLine(_ text: String, to handle: FileHandle) {
    handle.write(Data((text + "\n").utf8))
}

do {
    let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
    if let options = try EngramCLIResumeOptions.parse(arguments: arguments) {
        Task {
            do {
                let client = EngramServiceClient(
                    transport: UnixSocketEngramServiceTransport(socketPath: options.socketPath)
                )
                defer { client.close() }
                let rendered = try await EngramCLIResumeCommand.render(options: options, client: client)
                writeLine(rendered, to: .standardOutput)
                exit(0)
            } catch {
                writeLine(String(describing: error), to: .standardError)
                exit(1)
            }
        }
        dispatchMain()
    }
} catch {
    writeLine(String(describing: error), to: .standardError)
    exit(64)
}

let server = MCPStdioServer()
Task {
    await server.run()
    exit(0)
}
dispatchMain()

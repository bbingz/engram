import Darwin
import Foundation

if let archiveExitCode = runArchiveCommandIfRequested() {
    exit(archiveExitCode)
}

if let resumeExitCode = runResumeCommandIfRequested() {
    exit(resumeExitCode)
}

execSwiftMCPHelper()

func runArchiveCommandIfRequested() -> Int32? {
    do {
        guard let command = try EngramCLIArchiveCommand.parse(arguments: Array(CommandLine.arguments.dropFirst())) else {
            return nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do { print(try await EngramCLIArchiveRunner.run(command)) }
            catch { writeStderr("\(error)\n"); exitCode = 1 }
            semaphore.signal()
        }
        semaphore.wait()
        return exitCode
    } catch {
        writeStderr("\(error)\n")
        return 64
    }
}

func runResumeCommandIfRequested() -> Int32? {
    do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let options = try EngramCLIResumeOptions.parse(arguments: arguments) else {
            return nil
        }

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: options.socketPath)
        )
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                let output = try await EngramCLIResumeCommand.render(options: options, client: client)
                print(output)
                client.close()
            } catch {
                writeStderr("\(error)\n")
                exitCode = 1
                client.close()
            }
            semaphore.signal()
        }
        semaphore.wait()
        return exitCode
    } catch {
        writeStderr("\(error)\n")
        return 64
    }
}

func execSwiftMCPHelper() -> Never {
    guard let helperPath = mcpHelperCandidates().first(where: isExecutableFile) else {
        writeStderr("EngramCLI: EngramMCP helper not found. Use /Applications/Engram.app/Contents/Helpers/EngramMCP for MCP stdio.\n")
        exit(1)
    }

    let arguments = [helperPath] + Array(CommandLine.arguments.dropFirst())
    var cArguments = arguments.map { strdup($0) }
    cArguments.append(nil)
    defer {
        for argument in cArguments where argument != nil {
            free(argument)
        }
    }

    _ = cArguments.withUnsafeMutableBufferPointer { buffer in
        execv(helperPath, buffer.baseAddress)
    }
    writeStderr("EngramCLI: failed to exec EngramMCP at \(helperPath): \(String(cString: strerror(errno)))\n")
    exit(1)
}

func mcpHelperCandidates(
    executablePath: String = CommandLine.arguments.first ?? "",
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    var candidates: [String] = []
    if let override = environment["ENGRAM_CLI_MCP_HELPER"], !override.isEmpty {
        candidates.append(override)
    }

    let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
    let executableDirectory = executableURL.deletingLastPathComponent()
    candidates.append(executableDirectory.appendingPathComponent("EngramMCP").path)
    candidates.append(
        executableDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("EngramMCP")
            .path
    )
    candidates.append("/Applications/Engram.app/Contents/Helpers/EngramMCP")

    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
}

func isExecutableFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
        && FileManager.default.isExecutableFile(atPath: path)
}

func writeStderr(_ text: String) {
    if let data = text.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

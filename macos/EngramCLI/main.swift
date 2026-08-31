import Darwin
import Foundation

if let archiveExitCode = runArchiveCommandIfRequested() {
    exit(archiveExitCode)
}

if let resumeExitCode = runResumeCommandIfRequested() {
    exit(resumeExitCode)
}

if let contextExitCode = runContextCommandIfRequested() {
    exit(contextExitCode)
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

func runContextCommandIfRequested() -> Int32? {
    do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let options = try EngramCLIContextOptions.parse(arguments: arguments) else {
            return nil
        }
        let result = EngramCLIContextCommand.run(options: options)
        if !result.stdout.isEmpty {
            print(result.stdout)
        }
        return result.exitCode
    } catch {
        writeStderr("\(error)\n")
        return EngramCLIContextCommand.exitUsage
    }
}

func execSwiftMCPHelper() -> Never {
    let environment = ProcessInfo.processInfo.environment
    let socketPath: String
    let databasePath: String
    do {
        socketPath = try UnixSocketEngramServiceTransport.resolvedSocketPath(environment: environment)
        let rawDatabasePath = environment["ENGRAM_MCP_DB_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawDatabasePath, !rawDatabasePath.isEmpty {
            guard let normalized = UnixSocketEngramServiceTransport.normalizedAbsolutePath(rawDatabasePath) else {
                throw EngramServiceError.invalidRequest(
                    message: "ENGRAM_MCP_DB_PATH requires a non-empty absolute path"
                )
            }
            databasePath = normalized
        } else {
            databasePath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".engram/index.sqlite")
                .path
        }
    } catch {
        writeStderr("EngramCLI: \(error)\n")
        exit(64)
    }
    setenv("ENGRAM_MCP_SERVICE_SOCKET", socketPath, 1)
    setenv("ENGRAM_SERVICE_SOCKET", socketPath, 1)
    setenv("ENGRAM_MCP_DB_PATH", databasePath, 1)
    let executablePath = EngramCLIContextCommand.resolvedExecutablePath(
        argv0: CommandLine.arguments.first ?? ""
    ) ?? ""
    let candidates = EngramCLIContextCommand.mcpHelperCandidates(
        explicit: nil,
        executablePath: executablePath,
        environment: environment
    )
    guard let helperPath = candidates.first(where: EngramCLIContextCommand.isExecutableFile) else {
        writeStderr("EngramCLI: EngramMCP helper not found: \(candidates.joined(separator: ", "))\n")
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

func writeStderr(_ text: String) {
    if let data = text.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

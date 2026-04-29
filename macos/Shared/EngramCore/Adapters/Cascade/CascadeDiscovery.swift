import Foundation

enum CascadeDiscovery {
    static func discoverAntigravityClient(
        daemonDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/daemon")
            .path
    ) async -> CascadeClient? {
        discoverClientFromProcess() ?? discoverClientFromDaemonDir(daemonDir)
    }

    static func discoverWindsurfClient(
        daemonDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codeium/windsurf/daemon")
            .path
    ) async -> CascadeClient? {
        discoverClientFromDaemonDir(daemonDir)
    }

    static func discoverClientFromDaemonDir(_ daemonDir: String) -> CascadeClient? {
        let dir = URL(fileURLWithPath: daemonDir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? JSONLAdapterSupport.JSONObject,
                  let port = intValue(object["httpPort"]),
                  let csrfToken = JSONLAdapterSupport.string(object["csrfToken"]),
                  !csrfToken.isEmpty
            else {
                continue
            }
            return CascadeClient(port: port, csrfToken: csrfToken)
        }
        return nil
    }

    static func discoverClientFromProcess() -> CascadeClient? {
        guard let psOutput = run("/bin/ps", arguments: ["aux"]) else { return nil }
        guard let line = psOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { $0.contains("language_server_macos") || $0.contains("language_server_linux") })
        else {
            return nil
        }

        guard let csrfToken = firstMatch(in: line, pattern: #"--csrf_token\s+([^\s]+)"#),
              !csrfToken.isEmpty
        else {
            return nil
        }

        let fields = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count > 1 else { return nil }
        let pid = String(fields[1])
        let extensionPort = firstMatch(in: line, pattern: #"--extension_server_port\s+(\d+)"#)

        guard let lsofOutput = run("/usr/sbin/lsof", arguments: ["-i", "-P", "-n"]) else {
            return nil
        }

        for lsofLine in lsofOutput.split(separator: "\n").map(String.init) {
            let columns = lsofLine.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count > 1, String(columns[1]) == pid, lsofLine.contains("LISTEN") else {
                continue
            }
            guard let port = firstMatch(in: lsofLine, pattern: #":(\d+)\s+\(LISTEN\)"#),
                  port != extensionPort,
                  let portNumber = Int(port)
            else {
                continue
            }
            return CascadeClient(port: portNumber, csrfToken: csrfToken)
        }

        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func firstMatch(in string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string)
        else {
            return nil
        }
        return String(string[range])
    }

    private static func run(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

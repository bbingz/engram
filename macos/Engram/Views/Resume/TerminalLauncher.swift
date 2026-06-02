// macos/Engram/Views/Resume/TerminalLauncher.swift
import Foundation
import AppKit

enum TerminalType: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm2"
    case ghostty = "Ghostty"
    var id: String { rawValue }
}

struct TerminalLauncher {
    /// Escape a string for safe interpolation into AppleScript double-quoted strings.
    /// Internal visibility — used by RepoDetailView and other callers that build AppleScript.
    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func shellEscaped(_ value: String) -> String {
        EngramCLIResumeCommand.shellEscaped(value)
    }

    static func shellCommandLine(command: String, args: [String], cwd: String) -> String {
        let commandLine = ([command] + args)
            .map(shellEscaped)
            .joined(separator: " ")
        guard !cwd.isEmpty else { return commandLine }
        return "cd \(shellEscaped(cwd)) && \(commandLine)"
    }

    static func appleScriptCommandLine(command: String, args: [String], cwd: String) -> String {
        escapeForAppleScript(shellCommandLine(command: command, args: args, cwd: cwd))
    }

    static func launch(command: String, args: [String], cwd: String, terminal: TerminalType) {
        let shellCmd = shellCommandLine(command: command, args: args, cwd: cwd)
        // Reuse the single AppleScript-escaping helper instead of duplicating
        // the escapeForAppleScript(shellCommandLine(...)) chain inline.
        let appleScriptCmd = appleScriptCommandLine(command: command, args: args, cwd: cwd)
        let script: String
        switch terminal {
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "\(appleScriptCmd)"
            end tell
            """
        case .iterm:
            script = """
            tell application "iTerm2"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(appleScriptCmd)"
                end tell
            end tell
            """
        case .ghostty:
            let ghosttyBin = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
            if FileManager.default.isExecutableFile(atPath: ghosttyBin) {
                let logMsg = "[TerminalLauncher] Launching Ghostty: \(ghosttyBin) -e \(shellCmd)\n"
                try? logMsg.write(toFile: "/tmp/engram-terminal.log", atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ghosttyBin)
                process.arguments = ["-e", shellCmd]
                try? process.run()
                return
            }
            // Fallback: just activate via AppleScript if binary not found
            script = """
            tell application "Ghostty"
                activate
            end tell
            """
        }
        // Log the script for debugging
        let logMsg = "[TerminalLauncher] Executing script:\n\(script)\n"
        try? logMsg.write(toFile: "/tmp/engram-terminal.log", atomically: true, encoding: .utf8)

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                let errMsg = "[TerminalLauncher] AppleScript error: \(error)\n"
                if let data = errMsg.data(using: .utf8), let fh = FileHandle(forWritingAtPath: "/tmp/engram-terminal.log") {
                    fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                }
            }
        }
    }
}

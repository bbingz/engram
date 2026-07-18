// macos/Engram/Views/Resume/TerminalLauncher.swift
import Foundation
import AppKit

enum TerminalType: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm2"
    case ghostty = "Ghostty"
    case warp = "Warp"

    var id: String { rawValue }

    var bundleIdentifiers: [String] {
        switch self {
        case .terminal:
            return ["com.apple.Terminal"]
        case .iterm:
            return ["com.googlecode.iterm2"]
        case .ghostty:
            return ["com.mitchellh.ghostty"]
        case .warp:
            return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        }
    }

    var applicationPaths: [String] {
        switch self {
        case .terminal:
            return [
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Utilities/Terminal.app",
            ]
        case .iterm:
            return [
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app",
            ]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .warp:
            return ["/Applications/Warp.app"]
        }
    }
}

struct TerminalLauncher {
    enum LaunchError: LocalizedError {
        case appleScriptUnavailable
        case appleScriptError(String)
        case ghosttyBinaryUnavailable(String)
        case processRunFailed(String)
        case warpLaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .appleScriptUnavailable:
                return "Could not prepare terminal launch script."
            case .appleScriptError(let details):
                return "Terminal launch failed: \(details)"
            case .ghosttyBinaryUnavailable(let path):
                return "Ghostty executable was not found at \(path)."
            case .processRunFailed(let details):
                return "Terminal process launch failed: \(details)"
            case .warpLaunchFailed(let details):
                return "Warp launch failed: \(details)"
            }
        }
    }

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

    static func warpTabConfigTOML(configName: String, command: String, directory: String) -> String {
        """
        name = "\(tomlEscape(configName))"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "\(tomlEscape(directory))"
        commands = ["\(tomlEscape(command))"]
        """
    }

    static func ghosttyArguments(for shellCommand: String) -> [String] {
        ["-e", "/bin/zsh", "-lc", shellCommand]
    }

    static func availableTerminalTypes(
        bundleIdentifierIsInstalled: (String) -> Bool = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        },
        applicationPathExists: (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) -> [TerminalType] {
        let installed = TerminalType.allCases.filter { terminal in
            terminal.bundleIdentifiers.contains(where: bundleIdentifierIsInstalled)
                || terminal.applicationPaths.contains(where: applicationPathExists)
        }
        return installed.isEmpty ? [.terminal] : installed
    }

    private static func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func launchInWarp(shellCommand: String, cwd: String) throws {
        let tabConfigDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warp/tab_configs")
        try FileManager.default.createDirectory(at: tabConfigDir, withIntermediateDirectories: true)

        let configName = "engram-resume-\(UUID().uuidString.prefix(8).lowercased())"
        let configFile = tabConfigDir.appendingPathComponent("\(configName).toml")
        let directory = cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : cwd
        let toml = warpTabConfigTOML(
            configName: configName,
            command: shellCommand,
            directory: directory
        )
        try toml.write(to: configFile, atomically: true, encoding: .utf8)

        guard let url = URL(string: "warp://tab_config/\(configName)") else {
            throw NSError(
                domain: "TerminalLauncher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build Warp tab config URL"]
            )
        }

        let warpIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "dev.warp.Warp-Stable" || $0.bundleIdentifier == "dev.warp.Warp"
        }
        if warpIsRunning {
            guard NSWorkspace.shared.open(url) else {
                throw NSError(
                    domain: "TerminalLauncher",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Warp rejected the tab config URL"]
                )
            }
        } else {
            if let appURL = warpApplicationURL() {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
                    NSWorkspace.shared.open(url)
                }
            } else {
                guard NSWorkspace.shared.open(url) else {
                    throw NSError(
                        domain: "TerminalLauncher",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No app handled the Warp tab config URL"]
                    )
                }
            }
        }

        Task.detached {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            try? FileManager.default.removeItem(at: configFile)
        }
    }

    private static func warpApplicationURL() -> URL? {
        for bundleIdentifier in TerminalType.warp.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }
        for path in TerminalType.warp.applicationPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func launch(command: String, args: [String], cwd: String, terminal: TerminalType) -> Result<Void, LaunchError> {
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
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ghosttyBin)
                process.arguments = ghosttyArguments(for: shellCmd)
                do {
                    try process.run()
                    return .success(())
                } catch {
                    return .failure(.processRunFailed(error.localizedDescription))
                }
            }
            return .failure(.ghosttyBinaryUnavailable(ghosttyBin))
        case .warp:
            do {
                try launchInWarp(shellCommand: shellCmd, cwd: cwd)
                return .success(())
            } catch {
                return .failure(.warpLaunchFailed(error.localizedDescription))
            }
        }
        // SEC-M1: do not write resume command lines to /tmp (world-readable leak).

        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.appleScriptUnavailable)
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            return .failure(.appleScriptError(error.description))
        }
        return .success(())
    }
}

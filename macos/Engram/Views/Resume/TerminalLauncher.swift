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
    /// Escape a string for safe interpolation into AppleScript double-quoted strings
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func launch(command: String, args: [String], cwd: String, terminal: TerminalType) {
        let safeCwd = escapeForAppleScript(cwd)
        let safeCmd = ([command] + args).map { escapeForAppleScript($0) }.joined(separator: " ")
        let script: String
        switch terminal {
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(safeCwd)\\" && \(safeCmd)"
            end tell
            """
        case .iterm:
            script = """
            tell application "iTerm2"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "cd \\"\(safeCwd)\\" && \(safeCmd)"
                end tell
            end tell
            """
        case .ghostty:
            // Ghostty doesn't support AppleScript well; just activate it
            script = """
            tell application "Ghostty"
                activate
            end tell
            """
        }
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                print("[TerminalLauncher] AppleScript error: \(error)")
            }
        }
    }
}

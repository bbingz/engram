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
    static func launch(command: String, args: [String], cwd: String, terminal: TerminalType) {
        let fullCmd = ([command] + args).joined(separator: " ")
        let script: String
        switch terminal {
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(cwd)\\" && \(fullCmd)"
            end tell
            """
        case .iterm:
            script = """
            tell application "iTerm2"
                activate
                create window with default profile command "cd \\"\(cwd)\\" && \(fullCmd)"
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

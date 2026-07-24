// macos/Engram/Support/MCPActivationSupport.swift
// Pure helpers for mcp-activation-onboarding (rows 7/17/24/28).
import Foundation

// MARK: - Row 17: GitHub issue URL

enum GitHubIssueURL {
    static let repo = "https://github.com/bbingz/engram"

    static func reportIssue(version: String, build: String) -> URL {
        var components = URLComponents(string: "\(repo)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[Report] "),
            URLQueryItem(name: "body", value: "Version: \(version) (\(build))\n\n"),
        ]
        return components.url!
    }
}

// MARK: - Row 24: MCP client detection + activation gate

enum MCPClientDetection {
    /// True iff any mcpServers map (global or per-project) has a key named
    /// exactly "engram". Matches on the KEY, never the command path.
    static func isEngramConfigured(claudeJSON data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let global = root["mcpServers"] as? [String: Any], global["engram"] != nil {
            return true
        }
        if let projects = root["projects"] as? [String: Any] {
            for case let proj as [String: Any] in projects.values {
                if let servers = proj["mcpServers"] as? [String: Any], servers["engram"] != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Reads ~/.claude.json off-main; returns false if absent/unreadable.
    static func isEngramConfiguredOnDisk() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: path) else { return false }
        return isEngramConfigured(claudeJSON: data)
    }
}

enum MCPActivationGate {
    static func shouldShow(indexedSessions: Int, mcpConfigured: Bool, dismissed: Bool) -> Bool {
        indexedSessions > 0 && !mcpConfigured && !dismissed
    }
}

// MARK: - Row 28: verification ladder

enum MCPVerifyRung: Equatable {
    case resolve
    case execBit
    case handshake
    case socket
}

struct MCPVerifyResult: Equatable {
    let passed: Bool
    let failingRung: MCPVerifyRung?
    let remedy: String?
    let resolvedPath: String?
}

enum MCPVerificationLadder {
    static func verify(
        candidates: [String],
        isExecutable: (String) -> Bool,
        invoke: (String) -> EngramCLIContextCommand.MCPInvocationResult,
        serviceRunning: Bool,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> MCPVerifyResult {
        // Rung 1: resolve — a candidate that exists ON DISK.
        guard let path = candidates.first(where: { fileExists($0) }) else {
            return MCPVerifyResult(
                passed: false,
                failingRung: .resolve,
                remedy: "Engram MCP helper not found. Install Engram.app or set ENGRAM_MCP_PATH.",
                resolvedPath: nil
            )
        }
        // Rung 2: exec bit.
        guard isExecutable(path) else {
            return MCPVerifyResult(
                passed: false,
                failingRung: .execBit,
                remedy: "Helper found but not executable. Re-download Engram.app, or run: chmod +x \(path)",
                resolvedPath: path
            )
        }
        // Rung 3: live handshake.
        let result = invoke(path)
        if result.helperMissing {
            return MCPVerifyResult(
                passed: false,
                failingRung: .handshake,
                remedy: "Helper disappeared mid-launch. Re-download Engram.app.",
                resolvedPath: path
            )
        }
        if result.processFailed {
            return MCPVerifyResult(
                passed: false,
                failingRung: .handshake,
                remedy: "Helper crashed on launch. Check Console for com.engram logs.",
                resolvedPath: path
            )
        }
        if result.timedOut {
            return MCPVerifyResult(
                passed: false,
                failingRung: .handshake,
                remedy: "MCP handshake timed out. Ensure the Engram service is running.",
                resolvedPath: path
            )
        }
        if result.malformed {
            return MCPVerifyResult(
                passed: false,
                failingRung: .handshake,
                remedy: "Unexpected MCP response. Update Engram to match your MCP client.",
                resolvedPath: path
            )
        }
        // Rung 4: service socket.
        guard serviceRunning else {
            return MCPVerifyResult(
                passed: false,
                failingRung: .socket,
                remedy: "Handshake works but the Engram service is down; save_insight will fail. Start Engram or use the menu-bar Restart.",
                resolvedPath: path
            )
        }
        return MCPVerifyResult(passed: true, failingRung: nil, remedy: nil, resolvedPath: path)
    }
}

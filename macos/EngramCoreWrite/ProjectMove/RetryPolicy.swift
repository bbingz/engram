// macos/EngramCoreWrite/ProjectMove/RetryPolicy.swift
// Mirrors src/core/project-move/retry-policy.ts (Node parity baseline).
//
// Single source of truth for error → retry_policy classification + HTTP
// status mapping + message humanization. The Node module also carried the
// error-envelope builder consumed by MCP and HTTP layers; we keep that
// here so the two callers (Swift MCP + the EngramService command handler)
// share one contract.
import Foundation

public enum RetryPolicy: String, Codable, Equatable, Sendable {
    case safe
    case conditional
    case wait
    case never
}

/// Project-move-specific errors implement this so the pipeline can read
/// `errorName` (Node's `err.name`) without going through dynamic field
/// reflection that Swift doesn't support.
public protocol ProjectMoveError: Error {
    var errorName: String { get }
    var errorMessage: String { get }
    var errorDetails: ErrorDetails? { get }
}

public extension ProjectMoveError {
    var errorDetails: ErrorDetails? { nil }
}

/// Structured fields pulled off the error so clients (Swift UI, MCP AI
/// agents) can display "conflict dir: X" as a separate UI element with a
/// Copy button. Mirrors the `details` field shape over the wire.
public struct ErrorDetails: Codable, Equatable, Sendable {
    public var sourceId: String?
    public var oldDir: String?
    public var newDir: String?
    public var sharingCwds: [String]?
    public var migrationId: String?
    public var state: String?

    public init(
        sourceId: String? = nil,
        oldDir: String? = nil,
        newDir: String? = nil,
        sharingCwds: [String]? = nil,
        migrationId: String? = nil,
        state: String? = nil
    ) {
        self.sourceId = sourceId
        self.oldDir = oldDir
        self.newDir = newDir
        self.sharingCwds = sharingCwds
        self.migrationId = migrationId
        self.state = state
    }

    public var isEmpty: Bool {
        sourceId == nil && oldDir == nil && newDir == nil
            && sharingCwds == nil && migrationId == nil && state == nil
    }
}

public struct ErrorEnvelope: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public let name: String
        public let message: String
        public let retryPolicy: RetryPolicy
        public let details: ErrorDetails?

        enum CodingKeys: String, CodingKey {
            case name, message
            case retryPolicy = "retry_policy"
            case details
        }
    }

    public let error: Body
}

public enum RetryPolicyClassifier {
    /// Map an error name to the retry_policy clients should follow. Unknown
    /// errors default to `.never`: surfacing to the user is safer than
    /// encouraging a blind retry loop.
    public static func classify(errorName: String?) -> RetryPolicy {
        switch errorName {
        case "LockBusyError":
            return .wait
        case "ConcurrentModificationError":
            return .conditional
        case "DirCollisionError",
             "SharedEncodingCollisionError",
             "UndoStaleError",
             "UndoNotAllowedError",
             "InvalidUtf8Error":
            return .never
        default:
            return .never
        }
    }

    /// Map an error name to an HTTP status: 409 (state to resolve) or 500
    /// (genuine internal failure). 400 is reserved for caller-side input
    /// errors emitted at the MCP boundary (kept in the return type for
    /// future use).
    public static func httpStatus(errorName: String?) -> Int {
        switch errorName {
        case "LockBusyError",
             "DirCollisionError",
             "SharedEncodingCollisionError",
             "UndoNotAllowedError",
             "UndoStaleError":
            return 409
        default:
            return 500
        }
    }
}

/// Humanize Node-style fs error strings + strip orchestrator prefixes.
/// The greedy `[^']+` capture preserves commas inside quoted paths
/// (round-4 reviewer fix in the Node source).
public func sanitizeProjectMoveMessage(_ raw: String) -> String {
    guard !raw.isEmpty else { return "Unknown error" }
    var msg = raw
    for prefix in ["runProjectMove: ", "project-move: "] {
        if msg.hasPrefix(prefix) {
            msg = String(msg.dropFirst(prefix.count))
        }
    }
    msg = applyFsErrorTemplate(msg, code: "ENOENT", template: "File or directory not found")
    msg = applyFsErrorTemplate(msg, code: "EACCES", template: "Permission denied")
    msg = applyFsErrorTemplate(msg, code: "EEXIST", template: "Path already exists")
    return msg.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func applyFsErrorTemplate(_ raw: String, code: String, template: String) -> String {
    let pattern = "\\b\(code)\\b[^,]*,\\s*([a-z]+)\\s+'([^']+)'"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return raw
    }
    let nsRaw = raw as NSString
    let range = NSRange(location: 0, length: nsRaw.length)
    return regex.stringByReplacingMatches(
        in: raw,
        options: [],
        range: range,
        withTemplate: "\(template): $2 ($1)"
    )
}

/// Build the canonical error envelope returned over MCP / IPC. `sanitize`
/// follows Node convention: HTTP layer sanitizes; MCP keeps raw so the AI
/// agent sees the original text.
public func buildErrorEnvelope(_ err: Error, sanitize: Bool = false) -> ErrorEnvelope {
    let name: String
    let rawMessage: String
    let details: ErrorDetails?
    if let pm = err as? ProjectMoveError {
        name = pm.errorName
        rawMessage = pm.errorMessage
        details = pm.errorDetails
    } else {
        name = String(describing: type(of: err))
        rawMessage = err.localizedDescription
        details = nil
    }
    let message = sanitize ? sanitizeProjectMoveMessage(rawMessage) : rawMessage
    let policy = RetryPolicyClassifier.classify(errorName: name)
    let cleanDetails: ErrorDetails? = (details?.isEmpty == false) ? details : nil
    return ErrorEnvelope(
        error: ErrorEnvelope.Body(
            name: name,
            message: message,
            retryPolicy: policy,
            details: cleanDetails
        )
    )
}

/// MCP-specific multi-line guidance directing an AI agent on whether to
/// retry, what to tell the user, and how to resolve the condition. Used
/// as the `text` field in MCP error responses; structuredContent carries
/// the same envelope.
public func humanizeForMcp(_ err: Error) -> String {
    let name: String
    let base: String
    if let pm = err as? ProjectMoveError {
        name = pm.errorName
        base = pm.errorMessage
    } else {
        name = String(describing: type(of: err))
        base = err.localizedDescription
    }
    if let prefix = mcpGuidancePrefix(for: name) {
        return "\(prefix)\n\(base)"
    }
    return "\(name): \(base)"
}

private func mcpGuidancePrefix(for name: String) -> String? {
    switch name {
    case "LockBusyError":
        return "Another project-move is already running. Wait 5–10 seconds, then retry — but only if YOU did not start the other one. Never launch project_* tools in parallel."
    case "ConcurrentModificationError":
        return "A session file was modified while engram was patching it (another AI client likely wrote to it). Ask the user to stop editing the affected project in other tools, then retry once. Do NOT retry blindly."
    case "UndoStaleError":
        return "This migration can no longer be safely undone — its newPath is no longer owned by it (a later migration or manual edit overlaid it). Do not retry; tell the user."
    case "UndoNotAllowedError":
        return "Undo is only allowed for committed migrations. Use project_recover to diagnose failed/stuck ones."
    case "InvalidUtf8Error":
        return "A session file is not valid UTF-8; engram refused to patch to avoid data loss. The user must manually inspect/fix the file before retrying."
    case "DirCollisionError":
        return "The target directory already exists on disk for one of the session sources (see details.sourceId/newDir). Another project is using that path — engram refuses to overwrite. Tell the user to move the target aside (or pick a different destination) and retry."
    case "SharedEncodingCollisionError":
        return "The target dir is shared by multiple projects because this source uses a lossy encoding (e.g. iFlow/Gemini basename-per-project). Renaming would silently steal sessions from the other projects listed in details.sharingCwds. Do not retry; the user must manually separate the dirs."
    default:
        return nil
    }
}

// macos/Engram/Core/ToolCallParser.swift
import Foundation

// MARK: - Parsed Structures

struct ParsedToolCall {
    let toolName: String
    let parameters: [(key: String, value: String)]
    let rawContent: String
}

struct ParsedToolResult {
    let toolName: String?
    let output: String
    let isError: Bool
    let byteSize: Int
}

// MARK: - Parser

struct ToolCallParser {

    // Match "`ToolName`:" or "`ToolName(`"
    private static let toolCallHeaderPattern = try? NSRegularExpression(
        pattern: #"`([A-Za-z][A-Za-z0-9_]*)[`(]"#,
        options: []
    )

    // Common error signals in tool output
    private static let errorSignals: [String] = [
        "Error:", "ERROR:", "ENOENT:", "EACCES:", "EPERM:",
        "EXIT CODE", "Exit code:", "exit code", "Command failed",
        "command failed", "FAILED", "stderr:", "error:"
    ]

    // MARK: - parseToolCall

    /// Parse a tool call message. Returns nil if the content doesn't match Claude Code tool call format.
    static func parseToolCall(_ content: String) -> ParsedToolCall? {
        let prefix = String(content.prefix(500))

        guard let match = toolCallHeaderPattern?.firstMatch(
            in: prefix,
            range: NSRange(prefix.startIndex..., in: prefix)
        ) else { return nil }

        guard let nameRange = Range(match.range(at: 1), in: prefix) else { return nil }
        let toolName = String(prefix[nameRange])

        // Extract parameter block — content after the header line
        let params = extractParameters(from: content, toolName: toolName)

        return ParsedToolCall(toolName: toolName, parameters: params, rawContent: content)
    }

    // MARK: - parseToolResult

    /// Parse a tool result message. Returns nil if content doesn't match tool result format.
    static func parseToolResult(_ content: String) -> ParsedToolResult? {
        // Must contain at least one result signal to qualify
        let prefix = String(content.prefix(500))
        let knownSignals = ["tool_result", "⟪out⟫", "<local-command-stdout>", "<local-command-caveat>"]
        let isResult = knownSignals.contains { prefix.contains($0) }
        guard isResult else { return nil }

        // Check for errors
        let isError = errorSignals.contains { content.contains($0) }

        // Try to extract tool name from common result prefix patterns
        let toolName = extractResultToolName(from: content)

        // Strip wrapper tokens for cleaner display
        let output = cleanResultOutput(content)

        return ParsedToolResult(
            toolName: toolName,
            output: output,
            isError: isError,
            byteSize: content.utf8.count
        )
    }

    // MARK: - Parameter Extraction

    private static func extractParameters(from content: String, toolName: String) -> [(key: String, value: String)] {
        // Find everything after the first line (the header line)
        let lines = content.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        // The body is everything after the first line
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }

        // Try JSON first
        if let jsonParams = tryParseJSON(body) {
            return jsonParams
        }

        // Fallback: line-format "key: value"
        return parseLineFormat(body)
    }

    private static func tryParseJSON(_ text: String) -> [(key: String, value: String)]? {
        // Find first { ... } block
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let jsonSubstring = text[start...end]
        guard let data = jsonSubstring.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        return dict.map { key, value in
            let strValue: String
            if let s = value as? String {
                strValue = s
            } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
                      let s = String(data: data, encoding: .utf8) {
                strValue = s
            } else {
                strValue = "\(value)"
            }
            return (key: key, value: strValue)
        }.sorted { $0.key < $1.key }
    }

    private static func parseLineFormat(_ text: String) -> [(key: String, value: String)] {
        var params: [(key: String, value: String)] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Match "key: value" or "key = value"
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !key.contains(" ") {
                    params.append((key: key, value: value))
                }
            }
        }
        return params
    }

    // MARK: - Result Helpers

    private static func extractResultToolName(from content: String) -> String? {
        // Pattern: "Result from ToolName:" or "`ToolName` result"
        let patterns = [
            #"Result from `?([A-Za-z][A-Za-z0-9_]*)`?:"#,
            #"`([A-Za-z][A-Za-z0-9_]*)` result"#,
            #"Output of ([A-Za-z][A-Za-z0-9_]*):"#
        ]
        for pattern in patterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = re.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                return String(content[range])
            }
        }
        return nil
    }

    private static func cleanResultOutput(_ content: String) -> String {
        var cleaned = content
        // Strip common wrapper tokens
        let wrappers = ["tool_result", "⟪out⟫", "<local-command-stdout>", "</local-command-stdout>",
                        "<local-command-caveat>", "</local-command-caveat>"]
        for wrapper in wrappers {
            cleaned = cleaned.replacingOccurrences(of: wrapper, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

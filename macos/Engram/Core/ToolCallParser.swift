// macos/Engram/Core/ToolCallParser.swift
import Foundation

// MARK: - Parsed Structures

struct ParsedToolCall {
    let toolName: String
    let parameters: [(key: String, value: String)]
    let rawContent: String
    let preamble: String?
    let remainder: String?
}

struct ParsedToolResult {
    let toolName: String?
    let output: String
    let isError: Bool
    let byteSize: Int
}

// MARK: - Parser

struct ToolCallParser {

    // Match a header line in either the backticked colon form or the legacy
    // parenthesized form (`ToolName(` / ToolName().
    // This is a compile-time-constant pattern, so a failure means the literal
    // is malformed — surface it loudly instead of silently disabling ALL tool
    // call parsing via `try?` (which returns nil and degrades every transcript).
    private static let toolCallHeaderPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"^[ \t]*(?:`([A-Za-z][A-Za-z0-9_]*)`:|`?([A-Za-z][A-Za-z0-9_]*)\()"#,
                options: [.anchorsMatchLines]
            )
        } catch {
            preconditionFailure("ToolCallParser header regex failed to compile: \(error)")
        }
    }()

    // Result-name patterns: "Result from ToolName:", "`ToolName` result",
    // "Output of ToolName:". Precompiled once (mirrors toolCallHeaderPattern)
    // so extractResultToolName doesn't recompile them on every tool-result
    // render. Failures indicate a malformed literal — surface it loudly.
    private static let resultToolNamePatterns: [NSRegularExpression] = {
        let patterns = [
            #"Result from `?([A-Za-z][A-Za-z0-9_]*)`?:"#,
            #"`([A-Za-z][A-Za-z0-9_]*)` result"#,
            #"Output of ([A-Za-z][A-Za-z0-9_]*):"#
        ]
        return patterns.map { pattern in
            do {
                return try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            } catch {
                preconditionFailure("ToolCallParser result regex failed to compile: \(error)")
            }
        }
    }()

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

        guard let match = toolCallHeaderPattern.firstMatch(
            in: prefix,
            range: NSRange(prefix.startIndex..., in: prefix)
        ) else { return nil }

        let toolName = [1, 2].compactMap { capture in
            Range(match.range(at: capture), in: prefix).map { String(prefix[$0]) }
        }.first
        guard let toolName else { return nil }

        // Parameters may start on the matched header line. Keep only payload
        // text that was not consumed as structured parameters so compact
        // rendering never paints the same value twice.
        let payload = parameterPayload(
            from: content,
            afterHeaderUTF16Offset: match.range.location + match.range.length
        )
        let params = extractParameters(from: payload.text, sameLineValue: payload.sameLineValue)
        let preamble = extractPreamble(
            from: content,
            beforeHeaderUTF16Offset: match.range.location
        )
        let remainder = unparsedRemainder(
            from: payload.text,
            sameLineValue: payload.sameLineValue
        )

        return ParsedToolCall(
            toolName: toolName,
            parameters: params,
            rawContent: content,
            preamble: preamble,
            remainder: remainder
        )
    }

    // MARK: - parseToolResult

    /// Parse a tool result message. Returns nil if content doesn't match tool result format.
    static func parseToolResult(_ content: String) -> ParsedToolResult? {
        // Result wrappers are an envelope, not a substring classifier. A tool
        // call whose payload mentions e.g. `tool_result.json` stays a tool call.
        guard leadingResultEnvelope(in: content) != nil else { return nil }

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

    private static func extractPreamble(
        from content: String,
        beforeHeaderUTF16Offset headerStart: Int
    ) -> String? {
        guard headerStart > 0 else { return nil }
        let headerStartIndex = String.Index(utf16Offset: headerStart, in: content)
        let preamble = content[..<headerStartIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preamble.isEmpty ? nil : preamble
    }

    private static func parameterPayload(
        from content: String,
        afterHeaderUTF16Offset headerEnd: Int
    ) -> (text: String, sameLineValue: String?) {
        guard headerEnd < content.utf16.count else { return ("", nil) }
        let headerEndIndex = String.Index(utf16Offset: headerEnd, in: content)
        let suffix = content[headerEndIndex...]
        let lineEnd = suffix.firstIndex(of: "\n") ?? content.endIndex
        let sameLine = suffix[..<lineEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, sameLine.isEmpty ? nil : sameLine)
    }

    private static func extractParameters(
        from text: String,
        sameLineValue: String?
    ) -> [(key: String, value: String)] {
        guard !text.isEmpty else { return [] }

        // Try JSON first
        if let jsonParams = tryParseJSON(text) {
            return jsonParams
        }

        // Fallback: line-format "key: value"
        var parameters = parseLineFormat(text)
        if let sameLineValue,
           !parameters.contains(where: { $0.value == sameLineValue }) {
            parameters.insert((key: "input", value: sameLineValue), at: 0)
        }
        return parameters
    }

    private static func unparsedRemainder(
        from text: String,
        sameLineValue: String?
    ) -> String? {
        guard !text.isEmpty else { return nil }

        if tryParseJSON(text) != nil,
           let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            let suffixStart = text.index(after: end)
            let remainder = String(text[..<start]) + String(text[suffixStart...])
            let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var lines = text.components(separatedBy: "\n")
        if let sameLineValue,
           lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == sameLineValue {
            lines.removeFirst()
        }
        let remainder = lines.filter { parseLineFormat($0).isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
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
        let range = NSRange(content.startIndex..., in: content)
        for re in resultToolNamePatterns {
            if let match = re.firstMatch(in: content, range: range),
               let nameRange = Range(match.range(at: 1), in: content) {
                return String(content[nameRange])
            }
        }
        return nil
    }

    private static func cleanResultOutput(_ content: String) -> String {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let envelope = leadingResultEnvelope(in: cleaned) else {
            return cleaned
        }
        cleaned.removeSubrange(envelope.openRange)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if let closing = envelope.closing,
           cleaned.hasSuffix(closing) {
            cleaned.removeLast(closing.count)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func leadingResultEnvelope(
        in content: String
    ) -> (openRange: Range<String.Index>, closing: String?)? {
        let trimmed = content.drop(while: { $0.isWhitespace })
        let envelopes: [(open: String, closing: String?)] = [
            ("tool_result", nil),
            ("⟪out⟫", nil),
            ("<local-command-stdout>", "</local-command-stdout>"),
            ("<local-command-caveat>", "</local-command-caveat>"),
        ]
        for envelope in envelopes where trimmed.hasPrefix(envelope.open) {
            let end = trimmed.index(trimmed.startIndex, offsetBy: envelope.open.count)
            if envelope.open == "tool_result",
               end != trimmed.endIndex,
               !trimmed[end].isWhitespace {
                continue
            }
            return (trimmed.startIndex..<end, envelope.closing)
        }
        return nil
    }
}

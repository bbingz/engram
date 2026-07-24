// macos/Engram/Views/Transcript/ColorBarMessageView.swift
import SwiftUI

struct ColorBarMessageView: View {
    let indexed: IndexedMessage
    let searchText: String
    var onCopyAll: (() -> Void)? = nil
    @AppStorage("contentFontSize") var fontSize: Double = 14
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Per-row memo for find highlighting, keyed on the active query. Reference
    // type so `body` (non-mutating) can populate it; view identity is the
    // message id, so the effective key is (message id, searchText). See #27.
    @State private var highlightCache = HighlightCache()

    /// Compose OS Dynamic Type with the A± knob (row 31). Knob stays authoritative.
    private var effectiveFontSize: Double {
        Theme.scaledFontSize(base: fontSize, category: dynamicTypeSize)
    }

    private var barColor: Color { indexed.messageType.color }

    /// Tool-row content parsed exactly once per `body` evaluation, so the header
    /// label and the sub-view share a single parse instead of running
    /// ToolCallParser twice per render (#0).
    private enum ParsedRow {
        case toolCall(ParsedToolCall?)
        case toolResult(ParsedToolResult?)
        case plain

        var toolName: String? {
            switch self {
            case .toolCall(let parsed): return parsed?.toolName
            case .toolResult(let parsed): return parsed?.toolName
            case .plain: return nil
            }
        }
    }

    private var parsedRow: ParsedRow {
        switch indexed.messageType {
        case .toolCall, .tool:
            return .toolCall(ToolCallParser.parseToolCall(indexed.message.content))
        case .toolResult:
            return .toolResult(ToolCallParser.parseToolResult(indexed.message.content))
        default:
            return .plain
        }
    }

    /// Header label for a transcript row. Tool rows surface the concrete tool
    /// name (e.g. "TOOL: Read #2") when it can be parsed from the content,
    /// instead of the generic "TOOL CALL #N". Falls back to the type label.
    static func displayLabel(for type: MessageType, typeIndex: Int, content: String) -> String {
        let toolName: String?
        switch type {
        case .toolCall, .tool:
            toolName = ToolCallParser.parseToolCall(content)?.toolName
        case .toolResult:
            toolName = ToolCallParser.parseToolResult(content)?.toolName
        default:
            toolName = nil
        }
        return headerLabel(for: type, typeIndex: typeIndex, toolName: toolName)
    }

    /// Formats the header label from an already-resolved tool name, so callers
    /// that parsed the row once can reuse the result (see `body`).
    static func headerLabel(for type: MessageType, typeIndex: Int, toolName: String?) -> String {
        if let toolName, !toolName.isEmpty {
            return "TOOL: \(toolName) #\(typeIndex)"
        }
        return "\(type.label.uppercased()) #\(typeIndex)"
    }

    private var isPrimaryDialogue: Bool {
        indexed.messageType == .user || indexed.messageType == .assistant
    }

    private var messageBackground: Color {
        indexed.messageType == .user ? barColor.opacity(0.10) : Color.clear
    }

    private var shouldOutline: Bool {
        indexed.messageType == .user
    }

    @ViewBuilder
    private func roleHeader(_ label: String) -> some View {
        if indexed.messageType == .user {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(barColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(barColor.opacity(0.14))
                    .clipShape(Capsule())
                Spacer(minLength: 0)
            }
        } else if indexed.messageType == .assistant {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(barColor)
                Spacer(minLength: 0)
            }
        } else {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(barColor)
        }
    }

    private func highlightedText(_ text: String) -> AttributedString {
        guard !searchText.isEmpty else { return AttributedString(text) }
        // Memoize per query: unrelated re-renders (scroll, font-size change)
        // must not re-scan the full row content on the main thread (#27). The
        // cache lives per row, so the effective key is (message id, searchText).
        if highlightCache.query == searchText, let cached = highlightCache.value {
            return cached
        }
        let attr = Self.computeHighlight(text, searchText: searchText)
        highlightCache.query = searchText
        highlightCache.value = attr
        return attr
    }

    static func computeHighlight(_ text: String, searchText: String) -> AttributedString {
        var attr = AttributedString(text)
        guard !searchText.isEmpty else { return attr }
        // Search and map ranges against the SAME string (`text`) using a
        // case-insensitive search. Searching a lowercased copy and mapping the
        // indices back to the original misaligns on length-changing Unicode
        // (e.g. "ß".lowercased() stays one char but other casings change length).
        var searchStart = text.startIndex
        while let range = text.range(
            of: searchText,
            options: .caseInsensitive,
            range: searchStart..<text.endIndex
        ) {
            if let attrRange = Range(NSRange(range, in: text), in: attr) {
                attr[attrRange].backgroundColor = .yellow
                attr[attrRange].foregroundColor = .black
            }
            // Guard against zero-width matches (empty searchText already excluded).
            searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            if searchStart >= text.endIndex { break }
        }
        return attr
    }

    var body: some View {
        // Parse the row once; header label and tool sub-views share this result.
        let parsed = parsedRow
        let label = Self.headerLabel(
            for: indexed.messageType,
            typeIndex: indexed.typeIndex,
            toolName: parsed.toolName
        )
        return HStack(spacing: 0) {
            Rectangle()
                .fill(barColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                roleHeader(label)

                switch indexed.messageType {
                case .assistant, .code:
                    if searchText.isEmpty {
                        SegmentedMessageView(content: indexed.message.content)
                    } else {
                        Text(highlightedText(indexed.message.content))
                            .font(.system(size: effectiveFontSize))
                            .textSelection(.enabled)
                    }
                case .thinking:
                    Text(highlightedText(indexed.message.content))
                        .font(.system(size: effectiveFontSize))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .italic()
                case .toolCall:
                    if case let .toolCall(toolCall?) = parsed {
                        ToolCallView(parsed: toolCall)
                    } else {
                        Text(highlightedText(indexed.message.content))
                            .font(.system(size: effectiveFontSize))
                            .textSelection(.enabled)
                    }
                case .toolResult:
                    if case let .toolResult(toolResult?) = parsed {
                        ToolResultView(parsed: toolResult)
                    } else {
                        Text(highlightedText(indexed.message.content))
                            .font(.system(size: effectiveFontSize))
                            .textSelection(.enabled)
                    }
                case .system:
                    CollapsibleSystemBubble(message: indexed.message)
                default:
                    Text(highlightedText(indexed.message.content))
                        .font(.system(size: effectiveFontSize))
                        .textSelection(.enabled)
                        .foregroundStyle(indexed.messageType == .error ? barColor.opacity(0.85) : .primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(messageBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(shouldOutline ? barColor.opacity(0.16) : Color.clear, lineWidth: 1)
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 6, topTrailingRadius: 6
            )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(indexed.message.content, forType: .string)
            }
            if let onCopyAll {
                Button("Copy Entire Conversation", action: onCopyAll)
            }
        }
    }
}

/// Single-slot memo for a row's find highlighting. Keyed on the exact query
/// string (never a hashValue), and instance-scoped to the row's view identity
/// (the message id), so it holds the most recent (message id, searchText) result.
final class HighlightCache {
    var query: String?
    var value: AttributedString?
}

// macos/Engram/Views/Transcript/ColorBarMessageView.swift
import SwiftUI

struct ColorBarMessageView: View {
    let indexed: IndexedMessage
    let searchText: String
    var onCopyAll: (() -> Void)? = nil
    @AppStorage("contentFontSize") var fontSize: Double = 14

    private var barColor: Color { indexed.messageType.color }

    private var typeLabel: String {
        Self.displayLabel(for: indexed.messageType, typeIndex: indexed.typeIndex, content: indexed.message.content)
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
    private var roleHeader: some View {
        if indexed.messageType == .user {
            HStack(spacing: 6) {
                Text(typeLabel)
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
                Text(typeLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(barColor)
                Spacer(minLength: 0)
            }
        } else {
            Text(typeLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(barColor)
        }
    }

    private func highlightedText(_ text: String) -> AttributedString {
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
        HStack(spacing: 0) {
            Rectangle()
                .fill(barColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                roleHeader

                switch indexed.messageType {
                case .assistant, .code:
                    if searchText.isEmpty {
                        SegmentedMessageView(content: indexed.message.content)
                    } else {
                        Text(highlightedText(indexed.message.content))
                            .font(.system(size: fontSize))
                            .textSelection(.enabled)
                    }
                case .thinking:
                    Text(highlightedText(indexed.message.content))
                        .font(.system(size: fontSize))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .italic()
                case .toolCall:
                    if let parsed = ToolCallParser.parseToolCall(indexed.message.content) {
                        ToolCallView(parsed: parsed)
                    } else {
                        Text(highlightedText(indexed.message.content))
                            .font(.system(size: fontSize))
                            .textSelection(.enabled)
                    }
                case .toolResult:
                    if let parsed = ToolCallParser.parseToolResult(indexed.message.content) {
                        ToolResultView(parsed: parsed)
                    } else {
                        Text(highlightedText(indexed.message.content))
                            .font(.system(size: fontSize))
                            .textSelection(.enabled)
                    }
                case .system:
                    CollapsibleSystemBubble(message: indexed.message)
                default:
                    Text(highlightedText(indexed.message.content))
                        .font(.system(size: fontSize))
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

// macos/Engram/Views/Transcript/ColorBarMessageView.swift
import SwiftUI

struct ColorBarMessageView: View {
    let indexed: IndexedMessage
    let searchText: String
    @AppStorage("contentFontSize") var fontSize: Double = 14

    private var barColor: Color { indexed.messageType.color }

    private var typeLabel: String {
        "\(indexed.messageType.label.uppercased()) #\(indexed.typeIndex)"
    }

    private func highlightedText(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        guard !searchText.isEmpty else { return attr }
        let lower = text.lowercased()
        let query = searchText.lowercased()
        var searchStart = lower.startIndex
        while let range = lower.range(of: query, range: searchStart..<lower.endIndex) {
            if let attrRange = Range(NSRange(range, in: text), in: attr) {
                attr[attrRange].backgroundColor = .yellow
                attr[attrRange].foregroundColor = .black
            }
            searchStart = range.upperBound
        }
        return attr
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(barColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(typeLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(barColor)

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
        .background(barColor.opacity(0.06))
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
        }
    }
}

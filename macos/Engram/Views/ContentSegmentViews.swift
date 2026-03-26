// macos/Engram/Views/ContentSegmentViews.swift
import SwiftUI

// MARK: - Markdown Text Helper

/// Renders inline markdown (bold, italic, inline code, links, strikethrough)
struct MarkdownText: View {
    let text: String
    let fontSize: Double

    // Cache AttributedString results to avoid re-parsing markdown every render
    private static let attrCache = NSCache<NSString, CachedAttributedString>()

    private var attributed: AttributedString? {
        let key = NSString(string: String(text.hashValue))
        if let cached = Self.attrCache.object(forKey: key) { return cached.value }
        let result = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        Self.attrCache.setObject(CachedAttributedString(value: result), forKey: key)
        return result
    }

    var body: some View {
        if let attributed {
            Text(attributed)
                .font(.system(size: fontSize))
                .textSelection(.enabled)
        } else {
            Text(verbatim: text)
                .font(.system(size: fontSize))
                .textSelection(.enabled)
        }
    }
}

private class CachedAttributedString {
    let value: AttributedString?
    init(value: AttributedString?) { self.value = value }
}

// MARK: - Segment Cache Entry (reference type for NSCache)

private class SegmentCacheEntry {
    let segments: [ContentSegment]
    init(segments: [ContentSegment]) { self.segments = segments }
}

// MARK: - Segmented Message View

struct SegmentedMessageView: View {
    let content: String
    @AppStorage("contentFontSize") var fontSize: Double = 14

    // Cache parsed segments keyed by content hash — avoids re-parsing on every render
    private static let segmentCache = NSCache<NSString, SegmentCacheEntry>()

    private var segments: [ContentSegment] {
        let key = NSString(string: String(content.hashValue))
        if let cached = Self.segmentCache.object(forKey: key) {
            return cached.segments
        }
        let parsed = ContentSegmentParser.parse(content)
        let entry = SegmentCacheEntry(segments: parsed)
        Self.segmentCache.object(forKey: key)  // check again (race)
        Self.segmentCache.setObject(entry, forKey: key)
        return parsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segments) { segment in
                switch segment {
                case .text(let text):
                    MarkdownText(text: text, fontSize: fontSize)
                case .codeBlock(let lang, let code):
                    CodeBlockView(language: lang, code: code, fontSize: fontSize)
                case .heading(let level, let text):
                    HeadingView(level: level, text: text, fontSize: fontSize)
                case .bulletList(let items):
                    BulletListView(items: items, fontSize: fontSize)
                case .numberedList(let items):
                    NumberedListView(items: items, fontSize: fontSize)
                case .taskList(let items):
                    TaskListView(items: items, fontSize: fontSize)
                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows, fontSize: fontSize)
                case .horizontalRule:
                    Divider().padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Heading

struct HeadingView: View {
    let level: Int
    let text: String
    let fontSize: Double

    private var headingSize: Double {
        switch level {
        case 1: return fontSize + 8
        case 2: return fontSize + 5
        case 3: return fontSize + 3
        case 4: return fontSize + 1
        default: return fontSize
        }
    }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: headingSize, weight: .bold))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2)
        } else {
            Text(verbatim: text)
                .font(.system(size: headingSize, weight: .bold))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2)
        }
    }
}

// MARK: - Code Block

struct CodeBlockView: View {
    let language: String
    let code: String
    let fontSize: Double
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar with language + copy button
            HStack {
                if !language.isEmpty {
                    Text(verbatim: language)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption2)
                    .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                if !language.isEmpty {
                    Text(SyntaxHighlighter.highlight(code, language: language))
                        .font(.system(size: max(fontSize - 1, 10), design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                } else {
                    Text(verbatim: code)
                        .font(.system(size: max(fontSize - 1, 10), design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Bullet List

struct BulletListView: View {
    let items: [String]
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.secondary)
                    MarkdownText(text: item, fontSize: fontSize)
                }
            }
        }
        .padding(.leading, 4)
    }
}

// MARK: - Numbered List

struct NumberedListView: View {
    let items: [String]
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 4) {
                    Text(verbatim: "\(idx + 1).")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    MarkdownText(text: item, fontSize: fontSize)
                }
            }
        }
        .padding(.leading, 4)
    }
}

// MARK: - Task List

struct TaskListView: View {
    let items: [(done: Bool, text: String)]
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? .green : .secondary)
                        .font(.system(size: fontSize - 1))
                    MarkdownText(text: item.text, fontSize: fontSize)
                        .strikethrough(item.done, color: .secondary)
                        .foregroundStyle(item.done ? .secondary : .primary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Table

struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let fontSize: Double

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                // Header row
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(verbatim: header)
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color.secondary.opacity(0.1))

                Divider()

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(verbatim: cell)
                                .font(.system(size: fontSize - 1))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .background(rowIdx % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Collapsible System Bubble

struct CollapsibleSystemBubble: View {
    let message: ChatMessage
    @State private var isExpanded = false
    @AppStorage("contentFontSize") var fontSize: Double = 14

    private var categoryLabel: String {
        switch message.systemCategory {
        case .systemPrompt: return "System Prompt"
        case .agentComm:    return "Agent Communication"
        case .none:         return "System"
        }
    }

    private var categoryIcon: String {
        switch message.systemCategory {
        case .systemPrompt: return "doc.text"
        case .agentComm:    return "arrow.left.arrow.right"
        case .none:         return "gearshape"
        }
    }

    private var categoryColor: Color {
        switch message.systemCategory {
        case .systemPrompt: return .orange
        case .agentComm:    return .purple
        case .none:         return .gray
        }
    }

    private var previewLine: String {
        let first = message.content.components(separatedBy: CharacterSet.newlines).first ?? ""
        return String(first.prefix(80))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: categoryIcon)
                        .font(.caption)
                        .foregroundStyle(categoryColor)
                    Text(categoryLabel)
                        .font(.caption.bold())
                        .foregroundStyle(categoryColor)
                    if !isExpanded {
                        Text(verbatim: previewLine)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                Text(verbatim: message.content)
                    .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(categoryColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(categoryColor.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}

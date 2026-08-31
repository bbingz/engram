// macos/Engram/Views/Transcript/ToolCallView.swift
import SwiftUI

struct ToolCallView: View {
    let parsed: ParsedToolCall
    var searchText: String = ""
    @AppStorage("contentFontSize") var fontSize: Double = 14
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>? = nil
    @State private var expandedParams: Set<Int> = []

    private let tintColor = Color(red: 0.60, green: 0.32, blue: 0.85) // purple

    /// Compose OS Dynamic Type with the A± knob (row 31).
    private var effectiveFontSize: Double {
        Theme.scaledFontSize(base: fontSize, category: dynamicTypeSize)
    }

    private var rawContentMatchesSearch: Bool {
        let needle = ColorBarMessageView.normalizedFindNeedle(searchText)
        return !needle.isEmpty
            && parsed.remainder?.range(of: needle, options: .caseInsensitive) != nil
    }

    nonisolated static func renderedPreamble(parsed: ParsedToolCall, searchText: String) -> String? {
        let needle = ColorBarMessageView.normalizedFindNeedle(searchText)
        guard !needle.isEmpty,
              let preamble = parsed.preamble,
              preamble.range(of: needle, options: .caseInsensitive) != nil else { return nil }
        return preamble
    }

    nonisolated static func renderedRemainder(parsed: ParsedToolCall, searchText: String) -> String? {
        let needle = ColorBarMessageView.normalizedFindNeedle(searchText)
        guard !needle.isEmpty,
              let remainder = parsed.remainder,
              remainder.range(of: needle, options: .caseInsensitive) != nil else { return nil }
        return remainder
    }

    nonisolated static func findableContent(parsed: ParsedToolCall, searchText: String) -> String {
        var slices = [parsed.toolName]
        for parameter in parsed.parameters {
            slices.append(parameter.key)
            slices.append(parameter.value)
        }
        if let preamble = renderedPreamble(parsed: parsed, searchText: searchText) {
            slices.append(preamble)
        }
        if let remainder = renderedRemainder(parsed: parsed, searchText: searchText) {
            slices.append(remainder)
        }
        return slices.joined(separator: "\n")
    }

    /// Expose parser-owned prose before a tool header only when compact tool
    /// rendering hides the active raw-content match.
    private var preambleSlice: String? {
        Self.renderedPreamble(parsed: parsed, searchText: searchText)
    }

    private var remainderSlice: String? {
        Self.renderedRemainder(parsed: parsed, searchText: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: tool name badge
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: effectiveFontSize - 2))
                    .foregroundStyle(tintColor)
                Text(highlighted(parsed.toolName))
                    .font(.system(size: effectiveFontSize - 1, weight: .semibold))
                    .foregroundStyle(tintColor)
                Spacer()
                // Copy button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(parsed.rawContent, forType: .string)
                    copied = true
                    copyResetTask?.cancel()
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { copied = false }
                    }
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
            .padding(.vertical, 6)
            .background(tintColor.opacity(0.10))

            if let preambleSlice {
                Divider().overlay(tintColor.opacity(0.15))
                Text(highlighted(preambleSlice))
                    .font(.system(size: effectiveFontSize - 2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            if let remainderSlice {
                Divider().overlay(tintColor.opacity(0.15))
                Text(highlighted(remainderSlice))
                    .font(.system(size: effectiveFontSize - 2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            // Parameters
            if !parsed.parameters.isEmpty {
                Divider().overlay(tintColor.opacity(0.15))

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(parsed.parameters.enumerated()), id: \.offset) { idx, param in
                        parameterRow(idx: idx, key: param.key, value: param.value)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else if parsed.remainder != nil, remainderSlice == nil {
                // No structured params — show raw content collapsed
                rawFallbackView
            }
        }
        .background(tintColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tintColor.opacity(0.20), lineWidth: 1)
        )
        .onDisappear { copyResetTask?.cancel(); copyResetTask = nil }
    }

    @ViewBuilder
    private func parameterRow(idx: Int, key: String, value: String) -> some View {
        let isLong = value.count > 200
        let needle = ColorBarMessageView.normalizedFindNeedle(searchText)
        let isExpanded = expandedParams.contains(idx)
            || (isLong && !needle.isEmpty && value.range(of: needle, options: .caseInsensitive) != nil)

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 0) {
                Text(highlighted(key))
                    .font(.system(size: effectiveFontSize - 2, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 80, alignment: .leading)

                Text(": ")
                    .font(.system(size: effectiveFontSize - 2, design: .monospaced))
                    .foregroundStyle(.secondary)

                if isLong && !isExpanded {
                    HStack(alignment: .top, spacing: 4) {
                        Text(highlighted(String(value.prefix(200)) + "…"))
                            .font(.system(size: effectiveFontSize - 2, design: .monospaced))
                            .foregroundStyle(.primary)
                        Button("expand") {
                            expandedParams.insert(idx)
                        }
                        .font(.system(size: effectiveFontSize - 3))
                        .foregroundStyle(tintColor)
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(highlighted(value))
                            .font(.system(size: effectiveFontSize - 2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        if isLong && isExpanded {
                            Button("collapse") {
                                expandedParams.remove(idx)
                            }
                            .font(.system(size: effectiveFontSize - 3))
                            .foregroundStyle(tintColor.opacity(0.8))
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rawFallbackView: some View {
        let content = parsed.remainder ?? ""
        let lines = content.components(separatedBy: "\n")
        let isLong = lines.count > 5
        let isExpanded = expandedParams.contains(-1) || rawContentMatchesSearch

        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(tintColor.opacity(0.15))
            Text(highlighted(isLong && !isExpanded ? lines.prefix(5).joined(separator: "\n") + "\n…" : content))
                .font(.system(size: effectiveFontSize - 2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            if isLong {
                Button(isExpanded ? "Collapse" : "Show all") {
                    if isExpanded { expandedParams.remove(-1) } else { expandedParams.insert(-1) }
                }
                .font(.caption2)
                .foregroundStyle(tintColor)
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        ColorBarMessageView.highlightRendered(AttributedString(text), query: searchText)
    }
}

// macos/Engram/Views/Transcript/ToolCallView.swift
import SwiftUI

struct ToolCallView: View {
    let parsed: ParsedToolCall
    @AppStorage("contentFontSize") var fontSize: Double = 14
    @State private var copied = false
    @State private var expandedParams: Set<Int> = []

    private let tintColor = Color(red: 0.60, green: 0.32, blue: 0.85) // purple

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: tool name badge
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(tintColor)
                Text(parsed.toolName)
                    .font(.system(size: fontSize - 1, weight: .semibold))
                    .foregroundStyle(tintColor)
                Spacer()
                // Copy button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(parsed.rawContent, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
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
            } else if parsed.rawContent.count > 0 {
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
    }

    @ViewBuilder
    private func parameterRow(idx: Int, key: String, value: String) -> some View {
        let isLong = value.count > 200
        let isExpanded = expandedParams.contains(idx)

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 0) {
                Text(verbatim: key)
                    .font(.system(size: fontSize - 2, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 80, alignment: .leading)

                Text(": ")
                    .font(.system(size: fontSize - 2, design: .monospaced))
                    .foregroundStyle(.secondary)

                if isLong && !isExpanded {
                    HStack(alignment: .top, spacing: 4) {
                        Text(verbatim: String(value.prefix(200)) + "…")
                            .font(.system(size: fontSize - 2, design: .monospaced))
                            .foregroundStyle(.primary)
                        Button("expand") {
                            expandedParams.insert(idx)
                        }
                        .font(.system(size: fontSize - 3))
                        .foregroundStyle(tintColor)
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: value)
                            .font(.system(size: fontSize - 2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        if isLong && isExpanded {
                            Button("collapse") {
                                expandedParams.remove(idx)
                            }
                            .font(.system(size: fontSize - 3))
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
        let lines = parsed.rawContent.components(separatedBy: "\n")
        let isLong = lines.count > 5
        let isExpanded = expandedParams.contains(-1)

        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(tintColor.opacity(0.15))
            Text(verbatim: isLong && !isExpanded ? lines.prefix(5).joined(separator: "\n") + "\n…" : parsed.rawContent)
                .font(.system(size: fontSize - 2, design: .monospaced))
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
}

// macos/Engram/Views/Transcript/ToolResultView.swift
import SwiftUI

struct ToolResultView: View {
    let parsed: ParsedToolResult
    @AppStorage("contentFontSize") var fontSize: Double = 14

    private var lineCount: Int {
        parsed.output.components(separatedBy: "\n").count
    }

    @State private var isExpanded: Bool = false

    private var tintColor: Color {
        parsed.isError
            ? Color(red: 0.94, green: 0.27, blue: 0.27)  // red
            : Color(red: 0.15, green: 0.65, blue: 0.60)  // teal
    }

    private var headerIcon: String {
        parsed.isError ? "exclamationmark.circle" : "arrow.right.circle"
    }

    // Auto-collapse when >5 lines
    init(parsed: ParsedToolResult) {
        self.parsed = parsed
        _isExpanded = State(initialValue: parsed.output.components(separatedBy: "\n").count <= 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: headerIcon)
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(tintColor)

                    if let toolName = parsed.toolName {
                        Text(verbatim: toolName)
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .foregroundStyle(tintColor)
                    } else {
                        Text(parsed.isError ? "Error" : "Result")
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .foregroundStyle(tintColor)
                    }

                    Text(verbatim: "· \(formatSize(parsed.byteSize))")
                        .font(.system(size: fontSize - 3))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tintColor.opacity(0.10))
            }
            .buttonStyle(.plain)

            // Output content
            if isExpanded {
                Divider().overlay(tintColor.opacity(0.15))

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: parsed.output)
                        .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
                        .foregroundStyle(parsed.isError ? tintColor.opacity(0.85) : .primary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(tintColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tintColor.opacity(0.20), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB", kb)
        } else {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1f MB", mb)
        }
    }
}

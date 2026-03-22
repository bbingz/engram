// macos/Engram/Views/Observability/LogStreamView.swift
import SwiftUI
import GRDB

struct LogStreamView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var logs: [LogEntry] = []
    @State private var selectedLevel: String = "All"
    @State private var selectedModule: String = "All"
    @State private var availableModules: [String] = []
    @State private var isLoading = true

    private let levels = ["All", "debug", "info", "warn", "error"]
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Filters
            HStack(spacing: 12) {
                Picker("Level", selection: $selectedLevel) {
                    ForEach(levels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
                .frame(width: 140)

                Picker("Module", selection: $selectedModule) {
                    Text("All").tag("All")
                    ForEach(availableModules, id: \.self) { module in
                        Text(module).tag(module)
                    }
                }
                .frame(width: 180)

                Spacer()

                Text("\(logs.count) entries")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().opacity(0.3)

            // Log list
            if isLoading && logs.isEmpty {
                Spacer()
                ProgressView("Loading logs...")
                Spacer()
            } else if logs.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("No log entries")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            } else {
                List(logs) { entry in
                    LogRow(entry: entry)
                }
                .listStyle(.plain)
            }
        }
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
        .onChange(of: selectedLevel) { _, _ in Task { await loadData() } }
        .onChange(of: selectedModule) { _, _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try db.fetchLogs(level: selectedLevel, module: selectedModule, limit: 200)
            logs = result.entries
            if availableModules.isEmpty {
                availableModules = result.modules
            }
        } catch {
            print("LogStreamView error:", error)
        }
    }
}

// MARK: - Log Row

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(formatTimestamp(entry.ts))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .leading)

            LevelBadge(level: entry.level)

            Text(entry.module)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 80, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func formatTimestamp(_ ts: String) -> String {
        // Show just HH:MM:SS from ISO timestamp
        if let tIndex = ts.firstIndex(of: "T") {
            let time = ts[ts.index(after: tIndex)...]
            return String(time.prefix(8))
        }
        return String(ts.suffix(8))
    }
}

// MARK: - Level Badge

struct LevelBadge: View {
    let level: String

    private var color: Color {
        switch level {
        case "error": return .red
        case "warn":  return .orange
        case "info":  return .blue
        case "debug": return .gray
        default:      return .gray
        }
    }

    var body: some View {
        Text(level.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(width: 48)
    }
}

// MARK: - Model

struct LogEntry: Identifiable {
    let id: Int64
    let ts: String
    let level: String
    let module: String
    let message: String
    let traceId: String?
    let source: String
    let errorName: String?
    let errorMessage: String?
}

struct LogQueryResult {
    let entries: [LogEntry]
    let modules: [String]
}

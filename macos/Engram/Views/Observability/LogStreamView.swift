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
    @State private var cancellable: AnyDatabaseCancellable?

    private let levels = ["All", "debug", "info", "warn", "error"]

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
                .accessibilityIdentifier("observability_logLevelPicker")

                Picker("Module", selection: $selectedModule) {
                    Text("All").tag("All")
                    ForEach(availableModules, id: \.self) { module in
                        Text(module).tag(module)
                    }
                }
                .frame(width: 180)
                .accessibilityIdentifier("observability_logModulePicker")

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
                .accessibilityIdentifier("observability_logList")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_logStream")
        .onAppear { startObservation() }
        .onDisappear { cancellable?.cancel(); cancellable = nil }
        .onChange(of: selectedLevel) { _, _ in startObservation() }
        .onChange(of: selectedModule) { _, _ in startObservation() }
    }

    private func startObservation() {
        // Cancel any existing observation before starting a new one
        cancellable?.cancel()
        isLoading = true
        do {
            let level = selectedLevel
            let module = selectedModule
            cancellable = try db.observeLogs(
                level: level,
                module: module,
                limit: 200,
                onError: { error in
                    print("LogStreamView observation error:", error)
                },
                onChange: { result in
                    Task { @MainActor in
                        self.logs = result.entries
                        if self.availableModules.isEmpty {
                            self.availableModules = result.modules
                        }
                        self.isLoading = false
                    }
                }
            )
        } catch {
            print("LogStreamView error starting observation:", error)
            isLoading = false
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

struct LogEntry: Identifiable, Equatable {
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

struct LogQueryResult: Equatable {
    let entries: [LogEntry]
    let modules: [String]
}

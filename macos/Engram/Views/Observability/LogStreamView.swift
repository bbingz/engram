// macos/Engram/Views/Observability/LogStreamView.swift
import SwiftUI
import GRDB
import Combine

struct LogStreamView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var logs: [LogEntry] = []
    @State private var selectedLevel: String = "All"
    @State private var selectedModule: String = "All"
    @State private var availableModules: [String] = []
    @State private var isLoading = true
    @State private var logsUnavailable = false
    @State private var reloadTask: Task<Void, Never>? = nil

    // observability-4: no "warn" level — the unified log stores warnings at the
    // .error type, so a "warn" filter would always return 0 rows. Warnings appear
    // under "error".
    private let levels = ["All", "debug", "info", "error"]
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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

            if logsUnavailable {
                // OBS-C1: do not show a false-empty log when OSLogStore is blocked.
                AlertBanner(message: "System log not available under current permissions.")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

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
        .task { scheduleReload() }
        .onReceive(timer) { _ in scheduleReload() }
        .onChange(of: selectedLevel) { _, _ in scheduleReload() }
        .onChange(of: selectedModule) { _, _ in scheduleReload() }
        .onDisappear { reloadTask?.cancel(); reloadTask = nil }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { await reload() }
    }

    private func reload() async {
        // OBS-C1 / WP17: app-process lines (com.engram.app) come from the unified
        // log via OSLogReader, which is readable un-redacted for our own
        // subsystem. Service lines (com.engram.service) are hardcoded
        // `privacy: .private` in the system log, so we source them from the
        // service's SANITIZED in-process ring over IPC instead — otherwise the
        // viewer would only ever show "<private>" placeholders. Off-main (UI-C1/C2).
        isLoading = true
        let level = selectedLevel
        let module = selectedModule

        // App lines from OSLogStore (only com.engram.app; service lines route
        // through the ring below). osLogUnavailable degrades to the banner.
        var appLines: [LogEntry] = []
        var appModules: [String] = []
        var osLogUnavailable = false
        do {
            let result = try await Task.detached {
                try OSLogReader.recentLogs(level: level, module: module, hours: 24, limit: 200)
            }.value
            appLines = result.entries.filter { $0.source == "com.engram.app" }
            appModules = result.modules
        } catch is OSLogReaderError {
            osLogUnavailable = true
        } catch {
            EngramLogger.error("LogStreamView load failed", module: .ui, error: error)
        }

        // Service lines from the sanitized in-process ring over IPC.
        var serviceLines: [LogEntry] = []
        if let snapshot = try? await serviceClient.serviceLogs(level: nil, category: nil, limit: 200) {
            serviceLines = snapshot.lines.enumerated().map { index, line in
                LogEntry(
                    id: Int64(1_000_000 + index),
                    ts: line.timestamp,
                    level: line.level,
                    module: line.category,
                    message: line.message,
                    traceId: nil,
                    source: "com.engram.service",
                    errorName: nil,
                    errorMessage: nil
                )
            }
            .filter { level == "All" || $0.level == level }
            .filter { module == "All" || $0.module == module }
        }

        guard !Task.isCancelled else { return }

        // Merge, newest-first by timestamp, capped at 200.
        let merged = (appLines + serviceLines)
            .sorted { $0.ts > $1.ts }
            .prefix(200)
        logs = Array(merged)
        if availableModules.isEmpty {
            // Known service categories (mirror ServiceLogCategory, which lives in
            // the service-only target and isn't linked into the app) plus the
            // app modules OSLogReader observed.
            let serviceModules = ["runner", "ipc", "checkpoint", "writer", "reader", "ai"]
            availableModules = Array(Set(appModules + serviceModules)).sorted()
        }
        // Only banner when the app-log store is blocked AND we have no service
        // lines either, so a working service log isn't masked by an OSLog block.
        logsUnavailable = osLogUnavailable && serviceLines.isEmpty
        isLoading = false
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

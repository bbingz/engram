// macos/Engram/Views/Observability/ErrorDashboardView.swift
import SwiftUI
import GRDB

struct ErrorDashboardView: View {
    @Environment(DatabaseManager.self) var db
    @State private var totalErrors24h = 0
    @State private var errorsByModule: [(module: String, count: Int)] = []
    @State private var recentErrors: [LogEntry] = []
    @State private var isLoading = true
    @State private var logsUnavailable = false
    @State private var loadError: String? = nil

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if logsUnavailable {
                    // OBS-C1: do not render a false "all clear" when the unified
                    // log is not accessible — say so explicitly.
                    AlertBanner(message: "System log not available under current permissions — error data cannot be shown.")
                } else if let loadError {
                    AlertBanner(message: "Failed to load errors: \(loadError)")
                }
                // KPI
                HStack(spacing: 12) {
                    KPICard(value: "\(totalErrors24h)", label: "Errors (24h)")
                    KPICard(value: "\(errorsByModule.count)", label: "Affected Modules")
                }
                // observability-4: the unified log stores warnings at the error
                // type, so this count includes warning-level entries.
                Text("Includes warning-level entries (the unified log stores warnings at the error type).")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)

                // Errors by module
                SectionHeader(icon: "exclamationmark.triangle", title: "Errors by Module", badge: "24h")
                if errorsByModule.isEmpty {
                    Text("No errors in the last 24 hours")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(errorsByModule, id: \.module) { item in
                        HStack {
                            Text(item.module)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            Spacer()
                            Text("\(item.count)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.red)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Recent errors
                SectionHeader(icon: "exclamationmark.circle", title: "Recent Errors", badge: "last 20")
                if recentErrors.isEmpty {
                    Text("No recent errors")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(recentErrors) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                LevelBadge(level: entry.level)
                                Text(entry.module)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.secondaryText)
                                Spacer()
                                Text(formatTimestamp(entry.ts))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            Text(entry.message)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(3)
                            if let errorName = entry.errorName {
                                Text(errorName)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_errorDashboard")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        // OBS-C1: read real signal from the unified log (com.engram.*), not the
        // never-written `logs` table. Runs off the main thread (UI-C1/C2).
        do {
            let loaded = try await Task.detached { () -> (Int, [(module: String, count: Int)], [LogEntry]) in
                let total = try OSLogReader.countErrors(hours: 24)
                let byModule = try OSLogReader.errorsByModule(hours: 24)
                let recent = try OSLogReader.recentLogs(level: "error", hours: 24, limit: 20).entries.reversed()
                return (total, byModule, Array(recent))
            }.value
            totalErrors24h = loaded.0
            errorsByModule = loaded.1
            recentErrors = loaded.2
            logsUnavailable = false
            loadError = nil
        } catch is OSLogReaderError {
            logsUnavailable = true
        } catch {
            EngramLogger.error("ErrorDashboardView load failed", module: .ui, error: error)
            loadError = error.localizedDescription
        }
    }

}

// macos/Engram/Views/Observability/ErrorDashboardView.swift
import SwiftUI
import GRDB

struct ErrorDashboardView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var totalErrors24h = 0
    @State private var errorsByModule: [(module: String, count: Int)] = []
    @State private var recentErrors: [LogEntry] = []
    @State private var isLoading = true

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // KPI
                HStack(spacing: 12) {
                    KPICard(value: "\(totalErrors24h)", label: "Errors (24h)")
                    KPICard(value: "\(errorsByModule.count)", label: "Affected Modules")
                }

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
        .accessibilityIdentifier("observability_errorDashboard")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            totalErrors24h = try db.countErrors24h()
            errorsByModule = try db.errorsByModule24h()
            recentErrors = try db.recentErrors(limit: 20)
        } catch {
            print("ErrorDashboardView error:", error)
        }
    }

}

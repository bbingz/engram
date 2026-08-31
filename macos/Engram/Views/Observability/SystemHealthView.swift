// macos/Engram/Views/Observability/SystemHealthView.swift
//
// observability-5: the Health tab derives its signal entirely from real,
// app-readable sources — DB pragmas (size, journal mode), the live
// `EngramServiceStatusStore` (index-scan health), and the unified log's 24h
// error count via `OSLogReader`. It intentionally does NOT call
// `EngramServiceReadProvider.health()`, which is a constant stub that returns a
// hardcoded "healthy" payload with zero app callers; surfacing it would be a
// false all-clear.
//
import SwiftUI
import GRDB
import Combine

struct SystemHealthView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    @Environment(\.engramServiceClient) var serviceClient
    @State private var dbSize: Int64 = 0
    @State private var walMode: String? = nil
    @State private var errorCount24h: Int? = nil
    @State private var logsAvailable = true
    @State private var logCoverageComplete = true
    @State private var indexJobCounts: [String: Int] = [:]
    @State private var isLoading = true

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Database section
                SectionHeader(icon: "internaldrive", title: "Database", badge: nil)

                HStack(spacing: 12) {
                    KPICard(value: formatBytes(dbSize), label: "DB Size")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Database size")
                        .accessibilityValue(formatBytes(dbSize))
                    KPICard(value: db.path.components(separatedBy: "/").last ?? "index.sqlite", label: "DB File")
                }

                // Status indicators (driven by real signal, not hardcoded)
                SectionHeader(icon: "heart.fill", title: "Status", badge: nil)
                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(label: "SQLite Database", status: dbSize > 0 ? .ok : .warning)
                    // UI-M4: query PRAGMA journal_mode rather than hardcoding "OK".
                    StatusRow(
                        label: "Journal Mode" + (walMode.map { " (\($0))" } ?? ""),
                        status: walMode?.lowercased() == "wal" ? .ok : .warning
                    )
                    // OBS-O2: real index-scan health from the service status store.
                    StatusRow(label: indexScanLabel, status: indexScanStatus)
                }

                SectionHeader(icon: "tray.full", title: "Index jobs", badge: nil)
                VStack(alignment: .leading, spacing: 8) {
                    if indexJobRows.isEmpty {
                        Text("No index jobs recorded.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(indexJobRows) { row in
                            StatusRow(label: "\(row.label): \(row.count)", status: row.status)
                        }
                    }
                }

                // Errors (last 24h) from the unified log — OBS-C1.
                SectionHeader(icon: "exclamationmark.triangle", title: "Recent Errors", badge: "24h")
                if logsAvailable {
                    StatusRow(
                        label: "Errors logged (com.engram.*)",
                        status: errorCount24h.map {
                            $0 == 0 ? .ok : ($0 > 10 ? .error : .warning)
                        } ?? .warning
                    )
                    if let errorCount24h {
                        Text("\(errorCount24h) error-level entries across app and service logs over the last 24h.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Text("24-hour app and service log coverage is incomplete; partial counts are not shown.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    // OBS-C1: if OSLogStore is not accessible, say so honestly
                    // rather than rendering a false "all clear".
                    Text("System log not available under current permissions.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_health")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
    }

    private var indexScanLabel: String {
        switch serviceStatusStore.status {
        case .degraded(let message): return "Index scan — \(message)"
        case .error(let message): return "Service error — \(message)"
        case .running: return "Index scan healthy"
        case .starting: return "Service starting"
        case .stopped: return "Service stopped"
        }
    }

    private var indexScanStatus: StatusRow.HealthStatus {
        switch serviceStatusStore.status {
        case .running: return .ok
        case .starting: return .warning
        case .degraded: return .warning
        case .stopped, .error: return .error
        }
    }

    private struct IndexJobRow: Identifiable {
        let id: String
        let label: String
        let count: Int
        let status: StatusRow.HealthStatus
    }

    private var indexJobRows: [IndexJobRow] {
        [
            indexJobRow(id: "pending", label: "Pending", statuses: [.pending], status: .warning),
            indexJobRow(id: "running", label: "Running", statuses: [.running], status: .warning),
            indexJobRow(
                id: "retryable-failures",
                label: "Retryable failures",
                statuses: [.failed, .failedRetryable],
                status: .warning
            ),
            indexJobRow(
                id: "permanent-failures",
                label: "Permanent failures",
                statuses: [.failedPermanent, .failedTerminal],
                status: .error
            ),
            indexJobRow(id: "completed", label: "Completed", statuses: [.completed], status: .ok),
            indexJobRow(id: "not-applicable", label: "Not applicable", statuses: [.notApplicable], status: .ok),
        ]
        .filter { $0.count > 0 }
    }

    private func indexJobRow(
        id: String,
        label: String,
        statuses: [IndexJobStatus],
        status: StatusRow.HealthStatus
    ) -> IndexJobRow {
        let count = statuses.reduce(0) { partial, jobStatus in
            partial + (indexJobCounts[jobStatus.rawValue] ?? 0)
        }
        return IndexJobRow(id: id, label: label, count: count, status: status)
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        let db = self.db
        // UI-C1/C2 + OBS-C1: run DB PRAGMA + OSLogStore reads off the main thread.
        let appCoverageStartedAt = NSRunningApplication.current.launchDate ?? Date()
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let loaded = await Task.detached { () -> (Int64, String?, [String: Int], Int, Bool, Bool) in
            let size = db.dbSizeBytes()
            let wal = (try? db.journalMode())
            let indexJobs = (try? db.indexJobCountsByStatus()) ?? [:]
            do {
                let count = try OSLogReader.countErrors(hours: 24)
                return (size, wal, indexJobs, count, true, appCoverageStartedAt <= cutoff)
            } catch {
                return (size, wal, indexJobs, 0, false, false)
            }
        }.value
        let serviceSnapshot = try? await serviceClient.serviceLogs(level: "error", category: nil, limit: nil)
        let serviceErrors = serviceSnapshot.map {
            ObservabilityLogUnion.serviceEntries($0, hours: 24).count
        } ?? 0
        dbSize = loaded.0
        walMode = loaded.1
        indexJobCounts = loaded.2
        logsAvailable = loaded.4 || serviceSnapshot != nil
        logCoverageComplete = loaded.5 && serviceSnapshot.map {
            ObservabilityLogUnion.covers($0, hours: 24)
        } == true
        errorCount24h = logCoverageComplete ? loaded.3 + serviceErrors : nil
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes > 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes > 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes > 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}

// MARK: - Status Row

private struct StatusRow: View {
    let label: String
    let status: HealthStatus

    enum HealthStatus {
        case ok, warning, error

        var color: Color {
            switch self {
            case .ok:      return .green
            case .warning: return .orange
            case .error:   return .red
            }
        }

        var icon: String {
            switch self {
            case .ok:      return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.circle.fill"
            }
        }

        var text: String {
            switch self {
            case .ok:      return "OK"
            case .warning: return "Warning"
            case .error:   return "Error"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.icon)
                .scaledFont(12)
                .foregroundStyle(status.color)
            Text(label)
                .scaledFont(12)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Text(status.text)
                .scaledFont(11, weight: .medium)
                .foregroundStyle(status.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(status.text)
    }
}

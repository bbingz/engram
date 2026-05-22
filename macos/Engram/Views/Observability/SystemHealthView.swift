// macos/Engram/Views/Observability/SystemHealthView.swift
import SwiftUI
import GRDB

struct SystemHealthView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    @State private var dbSize: Int64 = 0
    @State private var walMode: String? = nil
    @State private var errorCount24h: Int = 0
    @State private var logsAvailable = true
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

                // Errors (last 24h) from the unified log — OBS-C1.
                SectionHeader(icon: "exclamationmark.triangle", title: "Recent Errors", badge: "24h")
                if logsAvailable {
                    StatusRow(
                        label: "Errors logged (com.engram.*)",
                        status: errorCount24h == 0 ? .ok : (errorCount24h > 10 ? .error : .warning)
                    )
                    Text("\(errorCount24h) error-level entries in the unified log over the last 24h.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
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

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        let db = self.db
        // UI-C1/C2 + OBS-C1: run DB PRAGMA + OSLogStore reads off the main thread.
        let loaded = await Task.detached { () -> (Int64, String?, Int, Bool) in
            let size = db.dbSizeBytes()
            let wal = (try? db.journalMode())
            do {
                let count = try OSLogReader.countErrors(hours: 24)
                return (size, wal, count, true)
            } catch {
                return (size, wal, 0, false)
            }
        }.value
        dbSize = loaded.0
        walMode = loaded.1
        errorCount24h = loaded.2
        logsAvailable = loaded.3
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
                .font(.system(size: 12))
                .foregroundStyle(status.color)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Text(status.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(status.text)
    }
}

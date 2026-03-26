// macos/Engram/Views/Observability/SystemHealthView.swift
import SwiftUI
import GRDB

struct SystemHealthView: View {
    @Environment(DatabaseManager.self) var db
    @State private var dbSize: Int64 = 0
    @State private var tableCounts: [(table: String, count: Int)] = []
    @State private var isLoading = true

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Database section
                SectionHeader(icon: "internaldrive", title: "Database", badge: nil)

                HStack(spacing: 12) {
                    KPICard(value: formatBytes(dbSize), label: "DB Size")
                    KPICard(value: db.path.components(separatedBy: "/").last ?? "index.sqlite", label: "DB File")
                }

                // Table row counts
                SectionHeader(icon: "tablecells", title: "Table Row Counts", badge: nil)

                if tableCounts.isEmpty && !isLoading {
                    Text("No tables found")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(tableCounts, id: \.table) { item in
                            HStack {
                                Text(item.table)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                Spacer()
                                Text(formatCount(item.count))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .padding(8)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // Status indicators
                SectionHeader(icon: "heart.fill", title: "Status", badge: nil)
                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(label: "SQLite Database", status: dbSize > 0 ? .ok : .warning)
                    StatusRow(label: "WAL Mode", status: .ok)
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_health")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        dbSize = db.dbSizeBytes()
        do {
            tableCounts = try db.observabilityTableCounts()
        } catch {
            print("SystemHealthView error:", error)
        }
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

    private func formatCount(_ count: Int) -> String {
        if count > 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count > 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
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
    }
}

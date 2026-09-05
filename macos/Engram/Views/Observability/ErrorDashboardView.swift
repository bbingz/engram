// macos/Engram/Views/Observability/ErrorDashboardView.swift
import SwiftUI
import GRDB
import Combine
import AppKit

struct ErrorDashboardView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(\.engramServiceClient) var serviceClient
    @State private var totalErrors24h: Int? = nil
    @State private var errorsByModule: [(module: String, count: Int)] = []
    @State private var recentErrors: [LogEntry] = []
    @State private var isLoading = true
    @State private var coverageHoles: [ErrorDashboardCoverageHole] = []

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !coverageHoles.isEmpty {
                    AlertBanner(message: coverageHoles.map(\.message).joined(separator: " "))
                }
                // KPI
                HStack(spacing: 12) {
                    KPICard(
                        value: totalErrors24h.map(String.init) ?? "—",
                        label: "Errors (24h)"
                    )
                    KPICard(
                        value: coverageHoles.isEmpty ? "\(errorsByModule.count)" : "—",
                        label: "Affected Modules"
                    )
                }
                // observability-4: the unified log stores warnings at the error
                // type, so this count includes warning-level entries.
                Text("Includes warning-level entries (the unified log stores warnings at the error type).")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)

                // Errors by module
                SectionHeader(icon: "exclamationmark.triangle", title: "Errors by Module", badge: "24h")
                if errorsByModule.isEmpty {
                    Text(totalErrors24h == nil ? "24-hour coverage is incomplete" : "No errors in the last 24 hours")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(errorsByModule, id: \.module) { item in
                        HStack {
                            Text(item.module)
                                .scaledFont(12, weight: .medium, design: .monospaced)
                            Spacer()
                            Text("\(item.count)")
                                .scaledFont(12, weight: .bold)
                                .foregroundStyle(Theme.red)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Recent errors
                SectionHeader(icon: "exclamationmark.circle", title: "Recent Errors", badge: "last 20")
                if recentErrors.isEmpty {
                    Text(coverageHoles.isEmpty ? "No recent errors" : "Recent error coverage is incomplete")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(recentErrors) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                LevelBadge(level: entry.level)
                                Text(entry.module)
                                    .scaledFont(10, weight: .medium, design: .monospaced)
                                    .foregroundStyle(Theme.secondaryText)
                                Spacer()
                                Text(formatTimestamp(entry.ts))
                                    .scaledFont(10, design: .monospaced)
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            Text(entry.message)
                                .scaledFont(11)
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(3)
                            if let errorName = entry.errorName {
                                Text(errorName)
                                    .scaledFont(10, design: .monospaced)
                                    .foregroundStyle(Theme.red)
                            }
                        }
                        .padding(8)
                        .background(Theme.red.opacity(0.05))
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
        let loaded = await ErrorDashboardLoader.load(
            appLoad: {
                try await Task.detached {
                    ErrorDashboardAppLogData(
                        entries: try OSLogReader.recentLogs(level: "error", hours: 24, limit: 20).entries,
                        errorCount24h: try OSLogReader.countErrors(hours: 24),
                        errorsByModule: try OSLogReader.errorsByModule(hours: 24),
                        coverageStartedAt: NSRunningApplication.current.launchDate ?? Date()
                    )
                }.value
            },
            serviceLoad: {
                try await serviceClient.serviceLogs(level: "error", category: nil, limit: nil)
            }
        )
        totalErrors24h = loaded.totalErrors24h
        errorsByModule = loaded.errorsByModule
        recentErrors = loaded.recentErrors
        coverageHoles = loaded.coverageHoles
    }
}

struct ErrorDashboardAppLogData {
    let entries: [LogEntry]
    let errorCount24h: Int
    let errorsByModule: [(module: String, count: Int)]
    let coverageStartedAt: Date

    init(
        entries: [LogEntry],
        errorCount24h: Int,
        errorsByModule: [(module: String, count: Int)],
        coverageStartedAt: Date = .distantPast
    ) {
        self.entries = entries
        self.errorCount24h = errorCount24h
        self.errorsByModule = errorsByModule
        self.coverageStartedAt = coverageStartedAt
    }
}

enum ErrorDashboardCoverageHole: Equatable {
    case appLogUnavailable
    case appLogTooYoung
    case serviceIPCFailed
    case serviceRingTooYoung

    var message: String {
        switch self {
        case .appLogUnavailable:
            return "App system log is unavailable, so 24-hour coverage is incomplete."
        case .appLogTooYoung:
            return "The app has been running for less than 24 hours, so app log coverage is incomplete."
        case .serviceIPCFailed:
            return "Service log IPC failed, so service errors are unavailable."
        case .serviceRingTooYoung:
            return "Service log history covers less than 24 hours."
        }
    }
}

struct ErrorDashboardLoadResult {
    let totalErrors24h: Int?
    let errorsByModule: [(module: String, count: Int)]
    let recentErrors: [LogEntry]
    let coverageHoles: [ErrorDashboardCoverageHole]
}

enum ErrorDashboardLoader {
    static func load(
        now: Date = Date(),
        appLoad: () async throws -> ErrorDashboardAppLogData,
        serviceLoad: () async throws -> ServiceLogSnapshot
    ) async -> ErrorDashboardLoadResult {
        let appData: ErrorDashboardAppLogData?
        do {
            appData = try await appLoad()
        } catch {
            EngramLogger.error("ErrorDashboardView app log load failed", module: .ui, error: error)
            appData = nil
        }

        let serviceSnapshot: ServiceLogSnapshot?
        let serviceIPCFailed: Bool
        do {
            serviceSnapshot = try await serviceLoad()
            serviceIPCFailed = false
        } catch {
            serviceSnapshot = nil
            serviceIPCFailed = true
        }

        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let appCovered = appData.map { $0.coverageStartedAt <= cutoff } == true
        let serviceCovered = serviceSnapshot.map {
            ObservabilityLogUnion.covers($0, hours: 24, now: now)
        } == true
        var holes: [ErrorDashboardCoverageHole] = []
        if appData == nil { holes.append(.appLogUnavailable) }
        else if !appCovered { holes.append(.appLogTooYoung) }
        if serviceIPCFailed {
            holes.append(.serviceIPCFailed)
        } else if !serviceCovered {
            holes.append(.serviceRingTooYoung)
        }

        let serviceEntries = serviceSnapshot.map {
            ObservabilityLogUnion.serviceEntries($0, hours: 24, now: now)
        } ?? []
        let recentEntries = ObservabilityLogUnion.merge(
            appData?.entries ?? [],
            serviceEntries,
            limit: 20
        )

        var errorsByModule: [(module: String, count: Int)] = []
        if holes.isEmpty {
            var moduleCounts = Dictionary(
                uniqueKeysWithValues: (appData?.errorsByModule ?? []).map { ($0.module, $0.count) }
            )
            for entry in serviceEntries {
                moduleCounts[entry.module, default: 0] += 1
            }
            errorsByModule = moduleCounts.map { entry in
                (module: entry.key, count: entry.value)
            }
            errorsByModule.sort { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.module < right.module
            }
        }
        let total = holes.isEmpty
            ? (appData?.errorCount24h ?? 0) + serviceEntries.count
            : nil

        return ErrorDashboardLoadResult(
            totalErrors24h: total,
            errorsByModule: errorsByModule,
            recentErrors: recentEntries,
            coverageHoles: holes
        )
    }
}

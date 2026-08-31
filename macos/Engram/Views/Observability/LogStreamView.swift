// macos/Engram/Views/Observability/LogStreamView.swift
import SwiftUI
import GRDB
import Combine

struct LogStreamView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(\.engramServiceClient) var serviceClient
    @State private var logs: [LogEntry] = []
    @State private var selectedLevel: String = "All"
    @State private var selectedModule: String = "All"
    @State private var availableModules: [String] = []
    @State private var isLoading = true
    @State private var logsUnavailable = false
    @State private var serviceLogsUnavailable = false
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
            } else if serviceLogsUnavailable {
                AlertBanner(message: "Service log feed unavailable — showing app-process logs only.")
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
                        .font(.system(size: 32)) // decorative empty-state icon: fixed size like EmptyState hero
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
            let (result, retainedErrors) = try await Task.detached {
                let recent = try OSLogReader.recentLogs(
                    level: level,
                    module: module,
                    hours: 24,
                    limit: 200
                )
                let errors = level == "All"
                    ? (try? OSLogReader.recentLogs(
                        level: "error",
                        module: module,
                        hours: 24,
                        limit: 200
                    ).entries) ?? []
                    : []
                return (recent, errors)
            }.value
            appLines = (result.entries + retainedErrors).filter { $0.source == "com.engram.app" }
            appModules = result.modules
        } catch is OSLogReaderError {
            osLogUnavailable = true
        } catch {
            EngramLogger.error("LogStreamView load failed", module: .ui, error: error)
        }

        // Service lines from the sanitized in-process ring over IPC.
        var serviceLines: [LogEntry] = []
        do {
            let serviceLevel = level == "All" ? nil : level
            let serviceCategory = module == "All" ? nil : module
            let snapshot = try await serviceClient.serviceLogs(
                level: serviceLevel,
                category: serviceCategory,
                limit: 200
            )
            let retainedErrors = level == "All"
                ? (try? await serviceClient.serviceLogs(
                    level: "error",
                    category: serviceCategory,
                    limit: nil
                )) ?? ServiceLogSnapshot(lines: [])
                : ServiceLogSnapshot(lines: [])
            serviceLines = ObservabilityLogUnion.serviceEntries(snapshot, hours: 24)
                + ObservabilityLogUnion.serviceEntries(retainedErrors, hours: 24)
            serviceLogsUnavailable = false
        } catch {
            serviceLogsUnavailable = true
        }

        guard !Task.isCancelled else { return }

        // Merge, newest-first by timestamp, capped at 200. The All view keeps
        // older errors visible even when newer informational chatter is full.
        logs = ObservabilityLogUnion.merge(
            appLines,
            serviceLines,
            limit: 200,
            reserveErrors: level == "All"
        )
        // L33: grow the module picker across reloads. Filling only when empty
        // dropped categories that appeared after the first poll (or only in
        // service ring lines).
        let observedModules = appModules + serviceLines.map(\.module)
        availableModules = LogStreamModuleCatalog.merging(
            existing: availableModules,
            observed: observedModules
        )
        // Only banner when the app-log store is blocked AND we have no service
        // lines either, so a working service log isn't masked by an OSLog block.
        logsUnavailable = osLogUnavailable && serviceLines.isEmpty
        isLoading = false
    }
}


// MARK: - Module catalog

/// Pure merge used by LogStreamView so late-appearing modules stay pickable.
enum LogStreamModuleCatalog {
    /// Known service categories (mirror ServiceLogCategory; service-only target).
    static let knownServiceModules = [
        "runner", "ipc", "checkpoint", "writer", "reader", "ai",
        "indexer", "index-jobs", "startup-backfill", "user-data-backup",
    ]

    static func merging(existing: [String], observed: [String], knownService: [String] = knownServiceModules) -> [String] {
        Array(Set(existing).union(observed).union(knownService)).sorted()
    }
}

// MARK: - Log Row

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(formatTimestamp(entry.ts))
                .scaledFont(10, design: .monospaced)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .leading)

            LevelBadge(level: entry.level)

            Text(entry.module)
                .scaledFont(10, weight: .medium, design: .monospaced)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 80, alignment: .leading)

            Text(entry.message)
                .scaledFont(11)
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
            .scaledFont(9, weight: .bold, design: .monospaced)
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
    var serviceSequence: UInt64? = nil
}

enum ObservabilityLogUnion {
    private struct EntryIdentity: Hashable {
        let ts: String
        let level: String
        let module: String
        let message: String
        let source: String
        let serviceSequence: UInt64?
    }

    static func date(from timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        return ISO8601DateFormatter().date(from: timestamp)
    }

    static func serviceEntries(
        _ snapshot: ServiceLogSnapshot,
        hours: Int? = nil,
        now: Date = Date()
    ) -> [LogEntry] {
        let cutoff = hours.map { now.addingTimeInterval(-Double($0) * 3_600) }
        return snapshot.lines.enumerated().compactMap { index, line in
            if let cutoff {
                guard let timestamp = date(from: line.timestamp), timestamp >= cutoff else {
                    return nil
                }
            }
            return LogEntry(
                id: Int64(1_000_000 + index),
                ts: line.timestamp,
                level: line.level,
                module: line.category,
                message: line.message,
                traceId: nil,
                source: "com.engram.service",
                errorName: nil,
                errorMessage: nil,
                serviceSequence: line.sequence ?? UInt64(index)
            )
        }
    }

    static func merge(
        _ app: [LogEntry],
        _ service: [LogEntry],
        limit: Int,
        reserveErrors: Bool = false
    ) -> [LogEntry] {
        let cap = max(0, limit)
        guard cap > 0 else { return [] }
        var seen = Set<EntryIdentity>()
        let ordered = (app + service)
            .filter { entry in
                seen.insert(EntryIdentity(
                    ts: entry.ts,
                    level: entry.level,
                    module: entry.module,
                    message: entry.message,
                    source: entry.source,
                    serviceSequence: entry.serviceSequence
                )).inserted
            }
            .sorted(by: isNewer)
        guard reserveErrors else { return Array(ordered.prefix(cap)) }

        var selected = Array(ordered.filter { $0.level == "error" }.prefix(cap))
        if selected.count < cap {
            selected.append(contentsOf: ordered.filter { $0.level != "error" }.prefix(cap - selected.count))
        }
        return selected.sorted(by: isNewer)
    }

    private static func isNewer(_ lhs: LogEntry, _ rhs: LogEntry) -> Bool {
        switch (date(from: lhs.ts), date(from: rhs.ts)) {
        case let (lhsDate?, rhsDate?):
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.ts > rhs.ts
        }
    }

    static func covers(_ snapshot: ServiceLogSnapshot, hours: Int, now: Date = Date()) -> Bool {
        guard let startedAt = snapshot.coverageStartedAt.flatMap(date(from:)) else { return false }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3_600)
        guard startedAt <= cutoff else { return false }
        guard snapshot.isTruncated else { return true }
        guard let oldestRetained = snapshot.lines.last.flatMap({ date(from: $0.timestamp) }) else {
            return false
        }
        return oldestRetained <= cutoff
    }
}

struct LogQueryResult: Equatable {
    let entries: [LogEntry]
    let modules: [String]
}

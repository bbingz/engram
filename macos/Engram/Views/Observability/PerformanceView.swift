// macos/Engram/Views/Observability/PerformanceView.swift
import SwiftUI
import Combine

struct PerformanceView: View {
    // OBS / observability-1: render real, bounded in-process telemetry from
    // EngramServiceClient.telemetry() (rolling scan counters + per-command
    // latency aggregates). Before any scan/command is recorded the snapshot is
    // collected-but-empty, so we show an honest "no data yet" EmptyState rather
    // than a false all-clear.
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var snapshot: ServiceTelemetrySnapshot?
    @State private var loadFailed = false

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "chart.line.uptrend.xyaxis", title: "Performance", badge: nil)

                if loadFailed {
                    EmptyState(
                        icon: "exclamationmark.triangle",
                        title: "Telemetry unavailable",
                        message: "Could not reach the Engram service to read performance counters."
                    )
                    .accessibilityIdentifier("performance_notAvailable")
                } else if let snapshot, hasData(snapshot) {
                    kpiRow(snapshot)
                    commandTable(snapshot)
                } else {
                    EmptyState(
                        icon: "speedometer",
                        title: "No performance data yet",
                        message: "Run a search or wait for the next index scan."
                    )
                    .accessibilityIdentifier("performance_empty")
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_performance")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
    }

    private func hasData(_ s: ServiceTelemetrySnapshot) -> Bool {
        s.scanCount > 0 || !s.commands.isEmpty
    }

    @ViewBuilder
    private func kpiRow(_ s: ServiceTelemetrySnapshot) -> some View {
        HStack(spacing: 12) {
            KPICard(
                value: s.lastScanDurationMs.map { String(format: "%.0f ms", $0) } ?? "—",
                label: "Last Scan"
            )
            KPICard(value: "\(s.lastScanIndexed) / \(s.lastScanTotal)", label: "Indexed / Total")
            KPICard(value: "\(s.scanCount)", label: "Scans")
        }
    }

    @ViewBuilder
    private func commandTable(_ s: ServiceTelemetrySnapshot) -> some View {
        if s.commands.isEmpty {
            EmptyState(
                icon: "list.bullet.rectangle",
                title: "No commands recorded yet",
                message: "Run a search or open a session to populate per-command latencies."
            )
        } else {
            SectionHeader(icon: "timer", title: "Command Latency", badge: nil)
            VStack(spacing: 0) {
                headerRow
                ForEach(s.commands.sorted { $0.count > $1.count }) { cmd in
                    latencyRow(cmd)
                }
            }
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            cell("Command", width: 140, align: .leading)
            cell("Count", width: 50, align: .trailing)
            cell("p50", width: 64, align: .trailing)
            cell("p95", width: 64, align: .trailing)
            cell("Max", width: 64, align: .trailing)
            cell("Err", width: 44, align: .trailing)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surfaceHighlight)
    }

    private func latencyRow(_ cmd: ServiceCommandLatency) -> some View {
        HStack(spacing: 8) {
            cell(cmd.command, width: 140, align: .leading)
            cell("\(cmd.count)", width: 50, align: .trailing)
            cell(String(format: "%.0f", cmd.p50Ms), width: 64, align: .trailing)
            cell(String(format: "%.0f", cmd.p95Ms), width: 64, align: .trailing)
            cell(String(format: "%.0f", cmd.maxMs), width: 64, align: .trailing)
            Text("\(cmd.errorCount)")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(cmd.errorCount > 0 ? Theme.red : Theme.secondaryText)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cmd.command)
        .accessibilityValue(
            "count \(cmd.count), p50 \(Int(cmd.p50Ms)) ms, p95 \(Int(cmd.p95Ms)) ms, max \(Int(cmd.maxMs)) ms, \(cmd.errorCount) errors"
        )
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .lineLimit(1)
            .frame(width: width, alignment: align)
    }

    private func loadData() async {
        do {
            let result = try await serviceClient.telemetry()
            snapshot = result
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}

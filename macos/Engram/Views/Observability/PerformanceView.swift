// macos/Engram/Views/Observability/PerformanceView.swift
import SwiftUI
import GRDB

struct PerformanceView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var hourlyMetrics: [HourlyMetric] = []
    @State private var slowTraces: [TraceEntry] = []
    @State private var isLoading = true

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // KPIs
                HStack(spacing: 12) {
                    KPICard(value: "\(hourlyMetrics.count)", label: "Metric Names")
                    KPICard(value: "\(slowTraces.count)", label: "Slow Traces (>1s)")
                }

                // Hourly metrics
                SectionHeader(icon: "chart.line.uptrend.xyaxis", title: "Recent Metrics", badge: "hourly")
                if hourlyMetrics.isEmpty {
                    Text("No metrics data yet")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(hourlyMetrics) { metric in
                        HStack(spacing: 12) {
                            Text(metric.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                HStack(spacing: 8) {
                                    MetricPill(label: "count", value: "\(metric.count)")
                                    MetricPill(label: "avg", value: String(format: "%.1f", metric.avg))
                                    if let p95 = metric.p95 {
                                        MetricPill(label: "p95", value: String(format: "%.1f", p95))
                                    }
                                }
                                Text(metric.hour)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Slow traces
                SectionHeader(icon: "tortoise", title: "Slow Traces", badge: ">1000ms")
                if slowTraces.isEmpty {
                    Text("No slow traces")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(slowTraces) { trace in
                        HStack(spacing: 8) {
                            Text(trace.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                            Text(trace.module)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            if let ms = trace.durationMs {
                                Text("\(ms)ms")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ms > 5000 ? .red : .orange)
                            }
                            StatusBadge(status: trace.status)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_performance")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            hourlyMetrics = try db.recentHourlyMetrics(limit: 50)
            slowTraces = try db.slowTraces(minDurationMs: 1000, limit: 20)
        } catch {
            print("PerformanceView error:", error)
        }
    }
}

// MARK: - Metric Pill

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

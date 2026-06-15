// macos/Engram/Views/Observability/TraceExplorerView.swift
import SwiftUI
import GRDB

struct TraceExplorerView: View {
    // OBS / observability-1: render the in-memory per-command span ring buffer
    // from EngramServiceClient.telemetry() newest-first. These are flat
    // per-IPC-command spans (not distributed traces), reset on service restart.
    // Before any command is recorded the buffer is collected-but-empty, so we
    // show an honest "no spans yet" EmptyState rather than a false-empty view.
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var spans: [ServiceSpan] = []
    @State private var loadFailed = false

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "point.3.connected.trianglepath.dotted", title: "Traces", badge: nil)

                if loadFailed {
                    EmptyState(
                        icon: "exclamationmark.triangle",
                        title: "Telemetry unavailable",
                        message: "Could not reach the Engram service to read recent spans."
                    )
                    .accessibilityIdentifier("traceExplorer_notAvailable")
                } else if spans.isEmpty {
                    EmptyState(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "No spans recorded yet",
                        message: "Run a search or open a session, then spans will appear here newest-first."
                    )
                    .accessibilityIdentifier("traceExplorer_empty")
                } else {
                    VStack(spacing: 0) {
                        // snapshot.spans is already newest-first
                        // (ServiceTelemetryCollector.snapshot reverses the ring
                        // buffer), so render as-is — no second reverse.
                        ForEach(spans) { span in
                            spanRow(span)
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
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_traceExplorer")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
    }

    private func spanRow(_ span: ServiceSpan) -> some View {
        HStack(spacing: 8) {
            StatusBadge(status: span.ok ? "ok" : "error")
            Text(span.command)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            if let err = span.errorName, !span.ok {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.red)
                    .lineLimit(1)
            }
            Spacer()
            Text(String(format: "%.0f ms", span.durationMs))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
            Text(relativeTime(span.startedAt))
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(span.command), \(span.ok ? "OK" : "error")")
        .accessibilityValue("\(Int(span.durationMs)) ms, \(relativeTime(span.startedAt))")
    }

    private func relativeTime(_ iso: String) -> String {
        guard let date = Self.isoFormatter.date(from: iso) else { return "" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 1 { return "now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        return "\(Int(elapsed / 3600))h ago"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func loadData() async {
        do {
            let snapshot = try await serviceClient.telemetry()
            spans = snapshot.spans
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}

// MARK: - Shared Status Badge

struct StatusBadge: View {
    let status: String

    private var color: Color {
        status == "error" ? .red : .green
    }

    var body: some View {
        Text(status.uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Model

struct TraceEntry: Identifiable {
    let id: Int64
    let traceId: String
    let spanId: String
    let parentSpanId: String?
    let name: String
    let module: String
    let startTs: String
    let endTs: String?
    let durationMs: Int?
    let status: String
    let attributes: String?
    let source: String
}

// MARK: - Hourly Metric Model

struct HourlyMetric: Identifiable {
    let id: Int64
    let name: String
    let type: String
    let hour: String
    let count: Int
    let sum: Double
    let min: Double
    let max: Double
    let p95: Double?

    var avg: Double {
        count > 0 ? sum / Double(count) : 0
    }
}

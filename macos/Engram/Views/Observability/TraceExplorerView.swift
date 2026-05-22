// macos/Engram/Views/Observability/TraceExplorerView.swift
import SwiftUI
import GRDB

struct TraceExplorerView: View {
    // OBS-C1: the Swift runtime never writes `traces` rows (no distributed-tracing
    // / signpost-span recording). The old `fetchTraces` read was therefore always
    // empty and showed a misleading "No traces found" as if the system were
    // healthy. Until span recording exists, report honestly that tracing is not
    // collected rather than rendering a false-empty explorer.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "point.3.connected.trianglepath.dotted", title: "Traces", badge: nil)
                EmptyState(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Tracing not collected",
                    message: "The Engram runtime does not record distributed-trace spans. See the Logs and Errors tabs for the signal the runtime actually emits."
                )
                .accessibilityIdentifier("traceExplorer_notAvailable")
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_traceExplorer")
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

// macos/Engram/Views/Observability/TraceExplorerView.swift
import SwiftUI
import GRDB

struct TraceExplorerView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var traces: [TraceEntry] = []
    @State private var nameFilter: String = ""
    @State private var expandedTraceId: Int64? = nil
    @State private var isLoading = true

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                    TextField("Filter by name...", text: $nameFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 300)

                Spacer()

                Text("\(traces.count) traces")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().opacity(0.3)

            // Trace list
            if isLoading && traces.isEmpty {
                Spacer()
                ProgressView("Loading traces...")
                Spacer()
            } else if traces.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("No traces found")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            } else {
                List(traces) { trace in
                    VStack(alignment: .leading, spacing: 0) {
                        // Main row
                        HStack(spacing: 8) {
                            // Expand indicator
                            Image(systemName: expandedTraceId == trace.id ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(width: 12)

                            Text(trace.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .lineLimit(1)

                            Text(trace.module)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)

                            Spacer()

                            if let ms = trace.durationMs {
                                Text("\(ms)ms")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(durationColor(ms))
                            }

                            StatusBadge(status: trace.status)

                            Text(formatTimestamp(trace.startTs))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedTraceId = expandedTraceId == trace.id ? nil : trace.id
                            }
                        }

                        // Expanded detail
                        if expandedTraceId == trace.id {
                            VStack(alignment: .leading, spacing: 4) {
                                DetailRow(label: "Trace ID", value: trace.traceId)
                                DetailRow(label: "Span ID", value: trace.spanId)
                                if let parent = trace.parentSpanId {
                                    DetailRow(label: "Parent", value: parent)
                                }
                                DetailRow(label: "Source", value: trace.source)
                                if let attrs = trace.attributes, !attrs.isEmpty {
                                    Text("Attributes:")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.secondaryText)
                                        .padding(.top, 2)
                                    Text(attrs)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(10)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.leading, 20)
                            .padding(.vertical, 4)
                            .padding(.bottom, 4)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .accessibilityIdentifier("observability_traceExplorer")
        .task { await loadData() }
        .onReceive(timer) { _ in Task { await loadData() } }
        .onChange(of: nameFilter) { _, _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            traces = try db.fetchTraces(nameFilter: nameFilter, limit: 100)
        } catch {
            print("TraceExplorerView error:", error)
        }
    }

    private func durationColor(_ ms: Int) -> Color {
        if ms > 5000 { return .red }
        if ms > 1000 { return .orange }
        return Theme.primaryText
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label + ":")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
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

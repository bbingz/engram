// macos/Engram/Views/Usage/CostSummarySection.swift
import SwiftUI

/// Display-only cost dashboard fed by `EngramServiceClient.costs()`.
/// Renders total spend, today/month-to-date, a per-source breakdown, and a
/// 30-day spend trend. It owns no fetching: the parent (SourcePulseView) loads
/// the `EngramServiceCostsResponse` and passes it in, plus loading/error flags
/// so the parent can keep the page rendered (never blank) on failure.
struct CostSummarySection: View {
    let costs: EngramServiceCostsResponse?
    var isLoading: Bool = false

    private var hasData: Bool {
        guard let costs else { return false }
        return costs.totalUsd > 0 || !costs.perSource.isEmpty || !costs.perDay.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "dollarsign.circle", title: "Cost")
                .help("Spend Engram can compute from indexed token usage. Not billing-authoritative.")

            if isLoading && costs == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading cost data…")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            } else if let costs, hasData {
                summaryRow(costs)
                if !costs.perSource.isEmpty {
                    perSourceBreakdown(costs.perSource)
                }
                if !costs.perDay.isEmpty {
                    trend(costs.perDay)
                }
            } else {
                EmptyState(
                    icon: "dollarsign.circle",
                    title: "No cost data yet",
                    message: "Cost shows up here once Engram has indexed sessions with token-usage data."
                )
            }
        }
    }

    @ViewBuilder
    private func summaryRow(_ costs: EngramServiceCostsResponse) -> some View {
        HStack(spacing: 12) {
            KPICard(value: Self.formatUsd(costs.totalUsd), label: "Total Spend")
            KPICard(value: Self.formatUsd(costs.todayUsd), label: "Today")
            KPICard(value: Self.formatUsd(costs.monthToDateUsd), label: "Month to Date")
        }
    }

    @ViewBuilder
    private func perSourceBreakdown(_ rows: [EngramServiceCostsResponse.SourceRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.sorted { $0.costUsd > $1.costUsd }) { row in
                HStack(spacing: 12) {
                    SourcePill(source: row.key)
                    Spacer()
                    Text("\(row.sessionCount) session\(row.sessionCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                    Text(Self.formatUsd(row.costUsd))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
        }
    }

    @ViewBuilder
    private func trend(_ days: [EngramServiceCostsResponse.DayRow]) -> some View {
        let recent = Array(days.suffix(30))
        let maxValue = recent.map(\.costUsd).max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text("Last 30 days")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(recent) { day in
                    let fraction = maxValue > 0 ? day.costUsd / maxValue : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.7))
                        .frame(height: max(2, CGFloat(fraction) * 56))
                        .frame(maxWidth: .infinity)
                        .help("\(day.day): \(Self.formatUsd(day.costUsd))")
                }
            }
            .frame(height: 56)
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    static func formatUsd(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }
}

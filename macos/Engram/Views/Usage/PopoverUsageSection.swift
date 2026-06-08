// macos/Engram/Views/Usage/PopoverUsageSection.swift
import SwiftUI

private func normalizedUsageStatus(_ status: String?) -> String? {
    guard let status else { return nil }
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
}

struct PopoverUsageSection: View {
    let usageData: [EngramServiceUsageItem]
    @State private var showAll = false

    private var groupedBySource: [(source: String, items: [EngramServiceUsageItem])] {
        Self.groupedUsageItemsBySource(usageData)
    }

    var body: some View {
        if !usageData.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("USAGE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(showAll ? "Collapse" : "Show All") {
                        showAll.toggle()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }

                if showAll {
                    // Expanded: all metrics grouped by source
                    ForEach(groupedBySource, id: \.source) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(SourceColors.label(for: group.source))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(SourceColors.color(for: group.source))
                            ForEach(group.items) { item in
                                UsageMetricRow(
                                    label: item.metric,
                                    value: item.value,
                                    unit: item.unit,
                                    limit: item.limit,
                                    resetAt: item.resetAt,
                                    status: item.status,
                                    metric: item.metric
                                )
                            }
                        }
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    // Compact: most actionable metric per source.
                    ForEach(groupedBySource, id: \.source) { group in
                        if let item = Self.compactUsageItem(from: group.items) {
                            UsageMetricRow(
                                label: SourceColors.label(for: group.source),
                                value: item.value,
                                unit: item.unit,
                                limit: item.limit,
                                resetAt: item.resetAt,
                                status: item.status,
                                metric: item.metric,
                                suffix: Self.windowSuffix(for: item.metric)
                            )
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    static func compactUsageItem(from items: [EngramServiceUsageItem]) -> EngramServiceUsageItem? {
        items.min { lhs, rhs in
            let lhsPriority = compactPriority(lhs)
            let rhsPriority = compactPriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsScore = compactPressureScore(lhs)
            let rhsScore = compactPressureScore(rhs)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return lhs.metric < rhs.metric
        }
    }

    static func groupedUsageItemsBySource(
        _ usageData: [EngramServiceUsageItem]
    ) -> [(source: String, items: [EngramServiceUsageItem])] {
        let grouped = Dictionary(grouping: usageData) { item in
            normalizedUsageSource(item.source)
        }
        return grouped
            .filter { !$0.key.isEmpty }
            .sorted { $0.key < $1.key }
            .map { (source: $0.key, items: $0.value) }
    }

    private static func normalizedUsageSource(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func windowSuffix(for metric: String) -> String {
        let normalized = metric.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("5h") { return "5h" }
        if normalized.contains("7d") { return "7d" }
        return ""
    }

    private static func compactPressureScore(_ item: EngramServiceUsageItem) -> Double {
        let metric = item.metric.lowercased()
        let value: Double
        if let limit = item.limit, limit > 0, item.unit != "%" {
            value = item.value / limit * 100
        } else {
            value = item.value
        }
        return metric.contains("remaining") ? 100 - value : value
    }

    private static func compactPriority(_ item: EngramServiceUsageItem) -> Int {
        switch normalizedUsageStatus(item.status) {
        case "critical":
            return 0
        case "attention":
            return 1
        default:
            break
        }

        let metric = item.metric.lowercased()
        if metric.contains("pressure")
            || metric.contains("used")
            || metric.contains("usage")
            || metric.contains("remaining") {
            return 2
        }
        if metric.contains("5h") && metric.contains("token") && metric.contains("share") {
            return 3
        }
        if metric.contains("7d") && metric.contains("token") && metric.contains("share") {
            return 4
        }
        if metric.contains("cost") && metric.contains("share") {
            return 5
        }
        if metric.contains("token") && metric.contains("total") {
            return 6
        }
        return 7
    }
}

struct UsageMetricRow: View {
    let label: String
    let value: Double
    var unit: String? = "%"
    var limit: Double? = nil
    var resetAt: String? = nil
    var status: String? = nil
    var metric: String? = nil
    var suffix: String = ""

    var body: some View {
        if Self.isPercent(unit) {
            UsageBar(
                label: label,
                value: value,
                limit: limit,
                resetAt: resetAt,
                status: status,
                metric: metric ?? label,
                suffix: suffix
            )
        } else {
            UsageValueRow(
                label: label,
                text: Self.formattedValue(value: value, unit: unit, limit: limit, suffix: suffix)
            )
        }
    }

    static func formattedValue(value: Double, unit: String?, limit: Double? = nil, suffix: String = "") -> String {
        if let limit {
            let base: String
            switch unit {
            case "tokens":
                base = "\(compactNumber(value))/\(compactNumber(limit)) tok"
            case "%", nil:
                base = "\(oneDecimalNumber(value))/\(oneDecimalNumber(limit))%"
            case "$":
                base = "$\(oneDecimalNumber(value))/$\(oneDecimalNumber(limit))"
            case let unit?:
                base = "\(oneDecimalNumber(value))/\(oneDecimalNumber(limit))\(unit)"
            }
            return suffix.isEmpty ? base : "\(base) \(suffix)"
        }

        let unitLabel: String
        let valueText: String
        switch unit {
        case "tokens":
            unitLabel = "tok"
            valueText = compactNumber(value)
        case let unit?:
            unitLabel = unit
            valueText = compactNumber(value)
        case nil:
            unitLabel = "%"
            valueText = "\(Int(value))"
        }

        let base = unitLabel == "%" ? "\(valueText)%" : "\(valueText) \(unitLabel)"
        return suffix.isEmpty ? base : "\(base) \(suffix)"
    }

    private static func isPercent(_ unit: String?) -> Bool {
        unit == nil || unit == "%"
    }

    private static func compactNumber(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        }
        return "\(Int(value.rounded()))"
    }

    private static func oneDecimalNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

struct UsageValueRow: View {
    let label: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

struct UsageBar: View {
    let label: String
    let value: Double
    var limit: Double? = nil
    var resetAt: String? = nil
    var status: String? = nil
    var metric: String? = nil
    var suffix: String = ""

    private var barColor: Color {
        switch normalizedUsageStatus(status) {
        case "critical": return .red
        case "attention": return .orange
        default: return .green
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * Self.fillFraction(value: value, metric: metric ?? label))
                }
            }
            .frame(height: 5)
            Text(Self.percentText(
                label: label,
                value: value,
                limit: limit,
                suffix: suffix,
                metric: metric
            ))
                .font(.system(size: 9))
                .foregroundStyle(normalizedUsageStatus(status) == "critical" ? .red : .secondary)
                .frame(
                    width: Self.valueTextWidth(label: label, limit: limit, suffix: suffix, metric: metric),
                    alignment: .trailing
                )
                .monospacedDigit()
        }
    }

    static func percentText(
        label: String,
        value: Double,
        limit: Double?,
        suffix: String,
        metric: String? = nil
    ) -> String {
        let base: String
        if let limit {
            base = "\(String(format: "%.1f", value))/\(String(format: "%.1f", limit))%"
        } else if (metric ?? label).lowercased().contains("remaining") {
            base = "\(Int(value))% (\(Int(max(0, 100 - value)))% used)"
        } else {
            base = "\(Int(value))%"
        }
        return suffix.isEmpty ? base : "\(base) \(suffix)"
    }

    static func fillFraction(value: Double, metric: String?) -> Double {
        let raw = (metric ?? "").lowercased().contains("remaining") ? 100 - value : value
        return min(max(raw / 100, 0), 1)
    }

    private static func valueTextWidth(label: String, limit: Double?, suffix: String, metric: String?) -> CGFloat {
        let semanticLabel = (metric ?? label).lowercased()
        if semanticLabel.contains("remaining"), limit == nil {
            return suffix.isEmpty ? 88 : 106
        }
        return limit == nil ? 40 : 72
    }
}

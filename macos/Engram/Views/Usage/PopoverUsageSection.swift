// macos/Engram/Views/Usage/PopoverUsageSection.swift
import SwiftUI

struct PopoverUsageSection: View {
    let usageData: [EngramServiceUsageItem]
    @State private var showAll = false

    private var groupedBySource: [(source: String, items: [EngramServiceUsageItem])] {
        let grouped = Dictionary(grouping: usageData, by: \.source)
        return grouped.sorted { $0.key < $1.key }.map { (source: $0.key, items: $0.value) }
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
                                UsageBar(label: item.metric, value: item.value, resetAt: item.resetAt)
                            }
                        }
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    // Compact: highest % per source
                    ForEach(groupedBySource, id: \.source) { group in
                        let highest = group.items.max(by: { $0.value < $1.value }) ?? group.items[0]
                        UsageBar(
                            label: SourceColors.label(for: group.source),
                            value: highest.value,
                            resetAt: highest.resetAt,
                            suffix: highest.metric.contains("5h") ? "5h" : highest.metric.contains("week") ? "wk" : ""
                        )
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct UsageBar: View {
    let label: String
    let value: Double
    var resetAt: String? = nil
    var suffix: String = ""

    private var barColor: Color {
        if value > 50 { return .green }
        if value >= 20 { return .orange }
        return .red
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
                        .frame(width: geo.size.width * min(value / 100, 1.0))
                }
            }
            .frame(height: 5)
            Text("\(Int(value))%\(suffix.isEmpty ? "" : " \(suffix)")")
                .font(.system(size: 9))
                .foregroundStyle(value < 20 ? .red : .secondary)
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

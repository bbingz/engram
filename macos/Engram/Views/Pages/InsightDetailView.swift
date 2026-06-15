// macos/Engram/Views/Pages/InsightDetailView.swift
import SwiftUI

/// Read-detail pane for a single DB insight. Pure presentation: renders the
/// full content plus metadata captions and a Delete button that invokes the
/// caller-provided closure. No direct service calls.
struct InsightDetailView: View {
    let insight: EngramServiceInsightInfo
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Insight").font(.headline).foregroundStyle(Theme.primaryText)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    HStack(spacing: 4) { Image(systemName: "trash"); Text("Delete") }
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityIdentifier("insight_delete")
            }

            HStack(spacing: 8) {
                if let wing = insight.wing, !wing.isEmpty { metaCaption("wing", wing) }
                if let room = insight.room, !room.isEmpty { metaCaption("room", room) }
                metaCaption("importance", String(insight.importance))
                if let createdAt = insight.createdAt, !createdAt.isEmpty { metaCaption("created", createdAt) }
            }

            Divider().opacity(0.2)

            Text(insight.content)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("insight_detail")
    }

    private func metaCaption(_ label: String, _ value: String) -> some View {
        Text("\(label): \(value)")
            .font(.caption)
            .foregroundStyle(Theme.tertiaryText)
    }
}

// macos/Engram/Components/SessionCard.swift
import SwiftUI

struct SessionCard: View {
    let session: Session
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 10) {
                SourcePill(source: session.source)

                Text(session.displayTitle)
                    .font(.callout)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let project = session.project {
                    ProjectBadge(project: project, source: session.source)
                }

                Text("\(session.messageCount) msgs")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)

                Text(relativeTime(session.startTime))
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 40, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return ""
        }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

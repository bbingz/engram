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

                // Human-driven cue: number of distinct asks (≥2). New info vs the
                // title, signals a multi-step session the human actively drove.
                if let asks = session.instructionCount, asks >= 2 {
                    Text("\(asks) asks")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("sessionCard_askCount")
                }

                Text("\(session.messageCount) msgs")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)

                Text(RelativeTimeText.format(session.startTime, style: .compact))
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
}

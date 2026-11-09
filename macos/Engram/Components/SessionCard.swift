// macos/Engram/Components/SessionCard.swift
import SwiftUI

struct SessionCard: View {
    let session: Session
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 10) {
                SourcePill(source: session.source)
                OriginBadge(origin: session.origin)

                Text(session.displayTitle)
                    .font(.callout)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                SessionValueBadge(session: session)

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
            .padding(.vertical, Theme.listRowVerticalPadding)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }
}

/// The existing search value bands, with a readable cue beyond color alone.
struct SessionValueBadge: View {
    let session: Session

    private var title: LocalizedStringKey {
        switch session.valueBand {
        case .high: return "High value"
        case .medium: return "Medium value"
        case .low: return "Low value"
        case .unknown: return ""
        }
    }

    var body: some View {
        if let score = session.qualityScore {
            Text(title)
                .font(.caption2)
                .foregroundStyle(session.valueBand == .high ? Theme.green : Theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.surfaceHighlight, in: Capsule())
                .fixedSize()
                .help(Text("Estimated from session activity. Score: \(score)."))
                .accessibilityLabel(Text(title) + Text(", score \(score)"))
                .accessibilityIdentifier("session_valueBand")
        }
    }
}

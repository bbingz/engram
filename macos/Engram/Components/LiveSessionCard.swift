// macos/Engram/Components/LiveSessionCard.swift
import SwiftUI

struct LiveSessionCard: View {
    let session: EngramServiceLiveSessionInfo
    var onOpen: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var levelColor: Color {
        switch session.activityLevel {
        case "active": return .green
        case "idle":   return .yellow
        default:       return .gray
        }
    }

    private var levelLabel: String {
        switch session.activityLevel {
        case "active": return "Active"
        case "idle":   return "Idle"
        default:       return "Recent"
        }
    }

    private var elapsedText: String {
        // Wave 7E L08: shared fractional-or-whole-second ISO parser.
        RelativeTimeText.format(session.lastModifiedAt, style: .agoWithSeconds)
    }

    var body: some View {
        if session.sessionId != nil, let onOpen {
            Button(action: onOpen) { cardBody }
                .buttonStyle(.plain)
                .help("Open session")
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        HStack(spacing: 10) {
            // Status dot — pulses only for active
            Circle()
                .fill(levelColor)
                .frame(width: 8, height: 8)
                .opacity(session.activityLevel == "active" && !reduceMotion && isPulsing ? 0.4 : 1.0)
                .motionAwareAnimation(
                    session.activityLevel == "active"
                        ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )

            SourcePill(source: session.source)

            VStack(alignment: .leading, spacing: 1) {
                if let project = session.project {
                    Text(project)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                if let title = session.title {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let model = session.model {
                Text(model.replacingOccurrences(of: "claude-", with: ""))
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Theme.secondaryText)
            }

            if let activity = session.currentActivity, session.activityLevel == "active" {
                Text(activity)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            }

            Text(elapsedText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(levelColor.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { if !reduceMotion { isPulsing = true } }
    }
}

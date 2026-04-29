// macos/Engram/Components/LiveSessionCard.swift
import SwiftUI

struct LiveSessionCard: View {
    let session: EngramServiceLiveSessionInfo

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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Use lastModifiedAt for "how long ago was it active"
        guard let date = formatter.date(from: session.lastModifiedAt) else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status dot — pulses only for active
            Circle()
                .fill(levelColor)
                .frame(width: 8, height: 8)
                .opacity(session.activityLevel == "active" && isPulsing ? 0.4 : 1.0)
                .animation(
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
        .onAppear { isPulsing = true }
    }
}

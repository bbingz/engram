// macos/Engram/Components/LiveSessionCard.swift
import SwiftUI

struct LiveSessionCard: View {
    let session: LiveSessionInfo

    @State private var isPulsing = false

    private var elapsedText: String {
        guard let started = session.startedAt else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: started) else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Pulse dot
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)

            SourcePill(source: session.source)

            if let project = session.project {
                Text(project)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
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

            if let activity = session.currentActivity {
                Text(activity)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            }

            if !elapsedText.isEmpty {
                Text(elapsedText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { isPulsing = true }
    }
}

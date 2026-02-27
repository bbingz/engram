// macos/CodingMemory/Views/SessionDetailView.swift
import SwiftUI

struct SessionDetailView: View {
    let session: Session
    @EnvironmentObject var db: DatabaseManager
    @State private var isFavorite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayTitle)
                            .font(.headline)
                        Text("\(session.source) · \(session.displayDate) · \(session.messageCount) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if isFavorite {
                            try? db.removeFavorite(sessionId: session.id)
                        } else {
                            try? db.addFavorite(sessionId: session.id)
                        }
                        isFavorite.toggle()
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let project = session.project {
                    Label(project, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !session.cwd.isEmpty {
                    Label(session.cwd, systemImage: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider()

                Text("Session ID")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Text(session.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .task {
            isFavorite = (try? db.isFavorite(sessionId: session.id)) ?? false
        }
    }
}

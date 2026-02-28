// macos/CodingMemory/Views/SessionDetailView.swift
import SwiftUI

struct SessionDetailView: View {
    let session: Session
    @EnvironmentObject var db: DatabaseManager
    @State private var isFavorite = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingMessages = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: headerView) {
                    if isLoadingMessages {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(32)
                    } else if messages.isEmpty {
                        Text(unsupportedMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        ForEach(messages) { msg in
                            MessageBubbleView(message: msg)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .task {
            isFavorite = (try? db.isFavorite(sessionId: session.id)) ?? false
        }
        .task(id: session.id) {
            isLoadingMessages = true
            messages = []
            let path = session.filePath
            let source = session.source
            messages = await Task.detached(priority: .userInitiated) {
                MessageParser.parse(filePath: path, source: source)
            }.value
            isLoadingMessages = false
        }
    }

    // MARK: - Header (pinned)

    var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
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

            HStack(spacing: 12) {
                if let project = session.project {
                    Label(project, systemImage: "folder")
                }
                if !session.cwd.isEmpty {
                    Label(session.cwd, systemImage: "terminal")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Helpers

    var unsupportedMessage: String {
        switch session.source {
        case "cursor", "opencode", "vscode":
            return "This source (\(session.source)) uses a SQLite database — conversation preview is not yet supported."
        default:
            return "No messages found."
        }
    }
}

// MARK: - Message bubble

struct MessageBubbleView: View {
    let message: ChatMessage

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isUser ? "person.circle.fill" : "sparkles")
                .font(.callout)
                .foregroundStyle(isUser ? Color.accentColor : .purple)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            Text(message.content)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isUser ? Color.accentColor.opacity(0.04) : Color.clear)
    }
}

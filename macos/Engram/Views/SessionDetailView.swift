// macos/Engram/Views/SessionDetailView.swift
import SwiftUI

struct SessionDetailView: View {
    let session: Session
    @EnvironmentObject var db: DatabaseManager
    @State private var isFavorite = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingMessages = false
    @State private var showRaw = false

    var displayMessages: [ChatMessage] {
        showRaw ? messages : messages.filter { !$0.isSystem }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: headerView) {
                    if session.sizeCategory != .normal {
                        HStack(spacing: 6) {
                            Image(systemName: session.sizeCategory == .huge
                                  ? "exclamationmark.triangle.fill"
                                  : "info.circle.fill")
                                .foregroundStyle(session.sizeCategory == .huge ? .red : .orange)
                            Text("This session is \(session.formattedSize) — loading may take a moment")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            (session.sizeCategory == .huge ? Color.red : Color.orange)
                                .opacity(0.08)
                        )
                    }
                    if isLoadingMessages {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(32)
                    } else if displayMessages.isEmpty && !messages.isEmpty {
                        // All messages were system injections
                        Text("No user-visible messages. Tap \"Raw\" to see raw content.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else if messages.isEmpty {
                        Text(unsupportedMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else if showRaw {
                        ForEach(displayMessages) { msg in
                            RawMessageRow(message: msg)
                            Divider().opacity(0.3)
                        }
                    } else {
                        ForEach(Array(displayMessages.enumerated()), id: \.element.id) { idx, msg in
                            CleanMessageBubble(message: msg, source: session.source)
                            // Subtle separator between assistant→user transitions
                            if idx < displayMessages.count - 1 {
                                let next = displayMessages[idx + 1]
                                if msg.role == "assistant" && next.role == "user" {
                                    Divider()
                                        .padding(.horizontal, 20)
                                        .opacity(0.25)
                                }
                            }
                        }
                        .padding(.bottom, 12)
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
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(session.source) · \(session.displayDate) · \(session.messageCount) msgs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Raw / Clean toggle
                Button {
                    showRaw.toggle()
                } label: {
                    Text(showRaw ? "Clean" : "Raw")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(showRaw ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12))
                        .foregroundStyle(showRaw ? .orange : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                // Favorite
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

    var unsupportedMessage: String {
        switch session.source {
        case "cursor", "opencode", "vscode":
            return "This source (\(session.source)) uses a SQLite database — conversation preview is not yet supported."
        default:
            return "No messages found."
        }
    }
}

// MARK: - Clean chat bubble

struct CleanMessageBubble: View {
    let message: ChatMessage
    let source: String

    var isUser: Bool { message.role == "user" }

    var assistantLabel: String {
        switch source {
        case "claude-code":  return "Claude"
        case "codex":        return "Codex"
        case "gemini-cli":   return "Gemini"
        case "kimi":         return "Kimi"
        case "qwen":         return "Qwen"
        case "cline":        return "Cline"
        case "cursor":       return "Cursor"
        case "windsurf":     return "Windsurf"
        case "antigravity":  return "Antigravity"
        default:             return source
        }
    }

    var body: some View {
        if isUser {
            // User: right-aligned bubble
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("You")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                        .padding(.trailing, 2)
                    Text(message.content)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        } else {
            // Assistant: left-aligned, no bubble background
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(.purple)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(assistantLabel)
                        .font(.caption.bold())
                        .foregroundStyle(.purple.opacity(0.8))
                    Text(message.content)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }
}

// MARK: - Raw message row

struct RawMessageRow: View {
    let message: ChatMessage

    var roleColor: Color {
        if message.isSystem { return .secondary }
        return message.role == "user" ? Color.accentColor : .purple
    }

    var roleLabel: String {
        if message.isSystem { return "[system]" }
        return message.role == "user" ? "[user]" : "[assistant]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(roleLabel)
                .font(.caption.monospaced().bold())
                .foregroundStyle(roleColor)
            Text(message.content)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(message.isSystem ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .opacity(message.isSystem ? 0.55 : 1.0)
    }
}

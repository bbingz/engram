// macos/Engram/Views/SessionDetailView.swift
import SwiftUI

// MARK: - Shared source display info

enum SourceDisplay {
    static func label(for source: String) -> String {
        switch source {
        case "claude-code":  return "Claude"
        case "codex":        return "Codex"
        case "copilot":      return "Copilot"
        case "gemini-cli":   return "Gemini"
        case "kimi":         return "Kimi"
        case "qwen":         return "Qwen"
        case "minimax":      return "MiniMax"
        case "lobsterai":    return "Lobster AI"
        case "cline":        return "Cline"
        case "cursor":       return "Cursor"
        case "windsurf":     return "Windsurf"
        case "antigravity":  return "Antigravity"
        case "opencode":     return "OpenCode"
        case "iflow":        return "iFlow"
        default:             return source
        }
    }

    static func color(for source: String) -> Color {
        SourceColors.color(for: source)
    }
}

struct SessionDetailView: View {
    let session: Session
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @State private var isFavorite = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingMessages = false
    @State private var showRaw = false
    @State private var isSummarizing = false
    @State private var summaryError: String? = nil
    @State private var currentSummary: String?

    @AppStorage("showSystemPrompts") var showSystemPrompts: Bool = false
    @AppStorage("showAgentComm") var showAgentComm: Bool = false
    @State private var displayMessages: [ChatMessage] = []

    private func updateDisplayMessages() {
        if showRaw {
            displayMessages = messages
        } else {
            displayMessages = messages.filter { msg in
                switch msg.systemCategory {
                case .none:         return true
                case .systemPrompt: return showSystemPrompts
                case .agentComm:    return showAgentComm
                }
            }
        }
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
                            .padding(40)
                    } else if displayMessages.isEmpty && !messages.isEmpty {
                        ContentUnavailableView {
                            Label("System Messages Only", systemImage: "eye.slash")
                        } description: {
                            Text("All messages are system injections. Tap \"Raw\" to see raw content.")
                        }
                        .padding(.top, 20)
                    } else if messages.isEmpty {
                        ContentUnavailableView {
                            Label("No Messages", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text(unsupportedMessage)
                        }
                        .padding(.top, 20)
                    } else if showRaw {
                        ForEach(displayMessages) { msg in
                            RawMessageRow(message: msg)
                            Divider().opacity(0.3)
                        }
                    } else {
                        ForEach(Array(displayMessages.enumerated()), id: \.element.id) { idx, msg in
                            if msg.isSystem {
                                CollapsibleSystemBubble(message: msg)
                            } else {
                                CleanMessageBubble(message: msg, source: session.source)
                            }
                            // Subtle separator between assistant→user transitions
                            if idx < displayMessages.count - 1 {
                                let next = displayMessages[idx + 1]
                                if msg.role == "assistant" && next.role == "user" && !next.isSystem {
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
            displayMessages = []
            let path = session.filePath
            let source = session.source
            messages = await Task.detached(priority: .userInitiated) {
                MessageParser.parse(filePath: path, source: source)
            }.value
            updateDisplayMessages()
            isLoadingMessages = false
        }
        .onChange(of: showRaw) { _, _ in updateDisplayMessages() }
        .onChange(of: showSystemPrompts) { _, _ in updateDisplayMessages() }
        .onChange(of: showAgentComm) { _, _ in updateDisplayMessages() }
    }

    // MARK: - Header (pinned)

    var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: currentSummary ?? session.displayTitle)
                        .font(.headline)
                        .lineLimit(3)
                    Text(verbatim: "\(session.source) · \(session.displayDate) · \(session.msgCountLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Summary button (if no summary yet)
                if currentSummary == nil && session.summary == nil && !isLoadingMessages {
                    Button {
                        Task { await generateSummary() }
                    } label: {
                        if isSummarizing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.purple)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSummarizing)
                    .help("Generate AI Summary")
                }

                // Raw / Clean toggle
                Button {
                    showRaw.toggle()
                } label: {
                    Text(showRaw ? LocalizedStringKey("Clean") : LocalizedStringKey("Raw"))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(showRaw ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12))
                        .foregroundStyle(showRaw ? .orange : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(showRaw ? "Show clean view" : "Show raw messages")

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
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            }

            HStack(spacing: 12) {
                if let project = session.project {
                    Label { Text(verbatim: project) } icon: { Image(systemName: "folder") }
                }
                if !session.cwd.isEmpty {
                    Label { Text(verbatim: session.cwd) } icon: { Image(systemName: "terminal") }
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            HStack(spacing: 4) {
                Text(verbatim: session.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .help("Copy session ID")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    var unsupportedMessage: LocalizedStringKey {
        switch session.source {
        case "vscode":
            return "This source (\(session.source)) uses a SQLite database — conversation preview is not yet supported."
        default:
            return "No messages found."
        }
    }

    func generateSummary() async {
        guard !messages.isEmpty else { return }
        isSummarizing = true
        summaryError = nil

        let daemonPort = indexer.port ?? 3457
        guard let url = URL(string: "http://127.0.0.1:\(daemonPort)/api/summary") else {
            summaryError = "Invalid daemon URL"
            isSummarizing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: String] = ["sessionId": session.id]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            if let httpResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let summary = json["summary"] as? String, !summary.isEmpty {
                    currentSummary = summary
                } else {
                    summaryError = "Empty response from AI"
                }
            } else {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let errorMsg = json?["error"] as? String ?? "Unknown error (HTTP \(httpResponse?.statusCode ?? 0))"
                summaryError = errorMsg
            }
        } catch {
            summaryError = "Network error: \(error.localizedDescription)"
        }

        isSummarizing = false
    }
}

// MARK: - Clean chat bubble

struct CleanMessageBubble: View {
    let message: ChatMessage
    let source: String
    @AppStorage("contentFontSize") var fontSize: Double = 14

    var isUser: Bool { message.role == "user" }

    var body: some View {
        if isUser {
            // User: right-aligned bubble
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("You")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(verbatim: message.content)
                        .font(.system(size: fontSize))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        } else {
            // Assistant: full-width with segmented content
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: SourceDisplay.label(for: source))
                    .font(.caption2.bold())
                    .foregroundStyle(SourceDisplay.color(for: source))
                VStack(alignment: .leading, spacing: 0) {
                    SegmentedMessageView(content: message.content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
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

    var roleLabel: LocalizedStringKey {
        if message.isSystem { return "[system]" }
        return message.role == "user" ? "[user]" : "[assistant]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(roleLabel)
                .font(.caption.monospaced().bold())
                .foregroundStyle(roleColor)
            Text(verbatim: message.content)
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

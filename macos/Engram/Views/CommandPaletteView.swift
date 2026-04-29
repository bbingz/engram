// macos/Engram/Views/CommandPaletteView.swift
import SwiftUI

struct CommandPaletteView: View {
    let onNavigate: (Screen) -> Void
    let onSelectSession: (String) -> Void

    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient

    @State private var query = ""
    @State private var sessionResults: [SessionHit] = []
    @State private var isSearching = false
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var isCommandMode: Bool { query.hasPrefix(">") }

    private var filteredCommands: [PaletteItem] {
        let commands = PaletteItem.navigationCommands(navigate: onNavigate)
        guard isCommandMode else { return [] }
        let search = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        if search.isEmpty { return commands }
        return commands.filter { $0.title.lowercased().contains(search) }
    }

    private var visibleItems: [AnyPaletteRow] {
        if isCommandMode {
            return filteredCommands.map { cmd in
                AnyPaletteRow(id: cmd.id, icon: cmd.icon, title: cmd.title, subtitle: nil, action: cmd.action)
            }
        } else {
            return sessionResults.map { hit in
                AnyPaletteRow(id: hit.id, icon: "bubble.left.and.bubble.right", title: hit.title, subtitle: hit.snippet) {
                    onSelectSession(hit.id)
                }
            }
        }
    }

    struct SessionHit: Identifiable {
        let id: String
        let title: String
        let snippet: String
        let date: String
    }

    struct AnyPaletteRow: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String?
        let action: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: isCommandMode ? "chevron.right" : "magnifyingglass")
                    .foregroundStyle(isCommandMode ? .blue : .secondary)
                    .font(.system(size: 14))
                TextField(isCommandMode ? "Type a command…" : "Search sessions… (> for commands)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .onSubmit { executeSelected() }
                    .onChange(of: query) { _, newValue in
                        selectedIndex = 0
                        if !isCommandMode && !newValue.isEmpty {
                            performSearch()
                        } else if newValue.isEmpty {
                            sessionResults = []
                        }
                    }
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                Button { dismiss() } label: {
                    Text("esc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            // Results
            if visibleItems.isEmpty && !query.isEmpty && !isSearching {
                VStack(spacing: 6) {
                    Text("No results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isCommandMode {
                        Text("Type > for navigation commands")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.isEmpty {
                VStack(spacing: 6) {
                    Text("Type to search sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Prefix with > for navigation commands")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            Button {
                                item.action()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 12))
                                        .frame(width: 20)
                                        .foregroundStyle(index == selectedIndex ? .white : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(index == selectedIndex ? .white : .primary)
                                        if let subtitle = item.subtitle {
                                            Text(subtitle)
                                                .font(.system(size: 11))
                                                .foregroundStyle(index == selectedIndex ? .white.opacity(0.7) : .secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(index == selectedIndex ? Color.accentColor : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < visibleItems.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func executeSelected() {
        guard !visibleItems.isEmpty, selectedIndex < visibleItems.count else { return }
        visibleItems[selectedIndex].action()
    }

    private func performSearch() {
        guard !query.isEmpty else { return }
        isSearching = true
        let q = query
        let db = self.db
        Task {
            do {
                let response = try await serviceClient.search(
                    EngramServiceSearchRequest(query: q, mode: "hybrid", limit: 10)
                )
                sessionResults = response.items.map { item in
                    SessionHit(
                        id: item.id,
                        title: item.generatedTitle ?? item.title ?? item.summary ?? item.project ?? "Untitled",
                        snippet: item.snippet ?? "",
                        date: item.startTime.map { String($0.prefix(10)) } ?? ""
                    )
                }
            } catch {
                let sessions = (try? await Task.detached {
                    try db.search(query: q, limit: 10)
                }.value) ?? []
                sessionResults = sessions.map { session in
                    SessionHit(
                        id: session.id,
                        title: session.displayTitle,
                        snippet: "",
                        date: session.displayDate
                    )
                }
            }
            isSearching = false
        }
    }
}

// macos/Engram/Views/CommandPaletteView.swift
import AppKit
import SwiftUI

typealias CommandPaletteExportState = SessionExportState

struct CommandPaletteView: View {
    let onNavigate: (Screen) -> Void
    let onSelectSession: (String) -> Void
    let onRefreshUsage: () -> Void
    let onRegenerateTitles: () -> Void

    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var sessionResults: [SessionHit] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var selectedIndex = 0
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var resumeSession: Session? = nil
    @State private var exportState: CommandPaletteExportState = .idle
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var isCommandMode: Bool { query.hasPrefix(">") }

    private var filteredCommands: [PaletteItem] {
        let commands = PaletteItem.navigationCommands(navigate: onNavigate)
            + PaletteItem.actionCommands(
                navigate: onNavigate,
                refreshUsage: onRefreshUsage,
                regenerateTitles: onRegenerateTitles
            )
        guard isCommandMode else { return [] }
        let search = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        if search.isEmpty { return commands }
        return commands.filter { $0.title.lowercased().contains(search) }
    }

    private var visibleItems: [PaletteItem] {
        if isCommandMode {
            return filteredCommands
        } else {
            return sessionResults.map { hit in
                PaletteItem.sessionResult(
                    id: hit.id,
                    title: hit.title,
                    subtitle: hit.snippet.isEmpty ? nil : hit.snippet,
                    onSelect: { onSelectSession(hit.id) },
                    onResume: { resume(id: hit.id) },
                    onExport: { export(id: hit.id) }
                )
            }
        }
    }

    /// Session-search result-state. Commands mode never "fails", so the failed
    /// branch only applies to keyword session search (`!isCommandMode`).
    private var searchOutcome: SearchOutcome {
        SearchOutcome.classify(
            query: query,
            isEmptyResults: visibleItems.isEmpty,
            didFail: searchFailed && !isCommandMode
        )
    }

    struct SessionHit: Identifiable {
        let id: String
        let title: String
        let snippet: String
        let date: String
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
                    .accessibilityIdentifier("commandPalette_search")
                    .onSubmit { executeSelected() }
                    .onChange(of: query) { _, newValue in
                        selectedIndex = 0
                        searchTask?.cancel()
                        if !isCommandMode && !newValue.isEmpty {
                            performSearch()
                        } else if newValue.isEmpty {
                            searchTask = nil
                            isSearching = false
                            sessionResults = []
                            searchFailed = false
                        } else {
                            searchTask = nil
                            isSearching = false
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

            // H12: export status is a banner over the list — never replaces results.
            if let status = exportState.statusText {
                HStack(spacing: 8) {
                    if exportState.isInFlight {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityIdentifier("commandPalette_exportProgress")
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle({
                            if case .failed = exportState { return Color.red }
                            return Color.secondary
                        }() as Color)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let path = exportState.revealPath {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)]
                            )
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityIdentifier("commandPalette_revealExport")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier("commandPalette_exportStatus")
                Divider()
            }

            // Results (always keep selection/list when exporting)
            if !query.isEmpty && !isSearching && searchOutcome == .failed {
                VStack(spacing: 6) {
                    Text("Search unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Could not reach the index. Try again.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleItems.isEmpty && !query.isEmpty && !isSearching {
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                paletteRow(item, isSelected: index == selectedIndex)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        guard visibleItems.indices.contains(newIndex) else { return }
                        MotionAware.animate(.default, reduceMotion: reduceMotion) {
                            proxy.scrollTo(visibleItems[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear { isFocused = true }
        .onDisappear { searchTask?.cancel(); searchTask = nil }
        .onKeyPress { keyPress in
            switch keyPress.key {
            case .upArrow:
                if selectedIndex > 0 { selectedIndex -= 1 }
                return .handled
            case .downArrow:
                if selectedIndex < visibleItems.count - 1 { selectedIndex += 1 }
                return .handled
            case .escape:
                dismiss()
                return .handled
            case .return:
                if keyPress.modifiers.contains(.command) {
                    runSecondary(0)
                    return .handled
                }
                if keyPress.modifiers.contains(.option) {
                    runSecondary(1)
                    return .handled
                }
                return .ignored
            default:
                return .ignored
            }
        }
        .sheet(item: $resumeSession) { session in
            ResumeDialog(session: session)
        }
    }

    @ViewBuilder
    private func paletteRow(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                item.action()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 12))
                        .frame(width: 20)
                        .foregroundStyle(isSelected ? .white : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? .white : .primary)
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Secondary affordances (Resume / Export) only on the selected row.
            if isSelected {
                ForEach(item.secondaryActions) { secondary in
                    let isExport = secondary.id.hasSuffix("-export")
                    Button {
                        secondary.run()
                    } label: {
                        Image(systemName: secondary.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help(secondary.label)
                    // H12: disable only the export affordance while one is in flight.
                    .disabled(isExport && !exportState.allowsExportAction)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func executeSelected() {
        guard !visibleItems.isEmpty, selectedIndex < visibleItems.count else { return }
        visibleItems[selectedIndex].action()
    }

    /// Run the Nth secondary action of the selected row (0 = Resume, 1 = Export).
    private func runSecondary(_ index: Int) {
        guard visibleItems.indices.contains(selectedIndex) else { return }
        let actions = visibleItems[selectedIndex].secondaryActions
        guard actions.indices.contains(index) else { return }
        actions[index].run()
    }

    private func resume(id: String) {
        let db = self.db
        Task {
            if let session = try? await Task.detached(operation: { try db.getSession(id: id) }).value {
                resumeSession = session
            }
        }
    }

    private func export(id: String) {
        // Capture-and-assign so @State observes the inFlight transition.
        var next = exportState
        guard next.begin(sessionId: id) else { return }
        exportState = next
        Task {
            let terminal: CommandPaletteExportState
            do {
                let response = try await serviceClient.exportSession(
                    EngramServiceExportSessionRequest(id: id, format: "markdown", outputHome: nil, actor: nil)
                )
                terminal = .succeeded(path: response.outputPath)
            } catch {
                terminal = .failed(message: "Export failed")
            }
            exportState = terminal
            // Auto-clear only if this terminal status is still showing (no newer export).
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if exportState == terminal {
                exportState = .idle
            }
        }
    }

    private func performSearch() {
        guard !query.isEmpty else { return }
        // Cancel any in-flight search before starting a new one — avoids racing
        // state writes and stops the old Task mutating state after dismiss.
        searchTask?.cancel()
        let q = query
        let db = self.db
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer {
                if !Task.isCancelled {
                    isSearching = false
                }
            }
            do {
                let response = try await serviceClient.search(
                    EngramServiceSearchRequest(query: q, mode: "keyword", limit: 10)
                )
                guard !Task.isCancelled else { return }
                searchFailed = false
                sessionResults = response.items.map { item in
                    SessionHit(
                        id: item.id,
                        title: item.generatedTitle ?? item.title ?? item.summary ?? item.project ?? "Untitled",
                        snippet: item.snippet ?? "",
                        date: item.startTime.map { String($0.prefix(10)) } ?? ""
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                // Wave 7E H11: match Search page double-fault semantics —
                // service failure + successful empty local FTS is empty results,
                // not infrastructure failure. Only when local FTS itself throws
                // (nil) do we mark search unavailable.
                do {
                    let sessions = try await Task.detached {
                        try db.search(query: q, limit: 10)
                    }.value
                    guard !Task.isCancelled else { return }
                    searchFailed = false
                    sessionResults = sessions.map { session in
                        SessionHit(
                            id: session.id,
                            title: session.displayTitle,
                            snippet: "",
                            date: session.displayDate
                        )
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    searchFailed = true
                    sessionResults = []
                }
            }
            guard !Task.isCancelled else { return }
        }
    }
}

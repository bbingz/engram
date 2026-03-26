// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @State private var searchQuery: String = ""
    @State private var showResume: Bool = false
    @State private var showPalette: Bool = false
    @State private var paletteItems: [PaletteItem] = []
    @State private var paletteSelection: Int = 0
    @Environment(DatabaseManager.self) var db
    @Environment(IndexerProcess.self) var indexer
    @Environment(DaemonClient.self) var daemonClient

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedScreen: $selectedScreen)
        } detail: {
            if let session = selectedSession {
                SessionDetailView(session: session, onBack: { selectedSession = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Spacer()

                // Command palette trigger
                Button { showPalette = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Search or command…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("⌘K")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 220)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                // Resume
                Button(action: { resumeSelectedSession() }) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 11))
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selectedSession == nil)
                .fixedSize()
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .navigationSplitViewStyle(.balanced)
        .background(Theme.background)
        .onChange(of: selectedScreen) { _, _ in
            // Clear session detail when navigating to a different page
            selectedSession = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notification in
            if let box = notification.object as? SessionBox {
                selectedSession = box.session
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToScreen)) { notification in
            if let rawValue = notification.object as? String,
               let screen = Screen(rawValue: rawValue) {
                selectedScreen = screen
            }
        }
        .sheet(isPresented: $showResume) {
            if let session = selectedSession {
                ResumeDialog(session: session)
                    .environment(indexer)
            }
        }
        .sheet(isPresented: $showPalette) {
            CommandPaletteView(
                onNavigate: { screen in
                    selectedScreen = screen
                    showPalette = false
                },
                onSelectSession: { id in
                    navigateToSession(id: id)
                    showPalette = false
                }
            )
            .environment(db)
            .environment(indexer)
            .frame(width: 480, height: 360)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        pageView(for: selectedScreen)
            .accessibilityIdentifier("\(selectedScreen.rawValue)_container")
    }

    @ViewBuilder
    private func pageView(for screen: Screen) -> some View {
        switch screen {
        case .home:
            HomeView()
        case .search:
            SearchPageView()
        case .sessions:
            SessionsPageView()
        case .timeline:
            TimelinePageView()
        case .activity:
            ActivityView()
        case .observability:
            ObservabilityView()
        case .hygiene:
            HygieneView()
        case .projects:
            ProjectsView()
        case .sourcePulse:
            SourcePulseView()
        case .repos:
            ReposView()
        case .workGraph:
            WorkGraphView()
        case .skills:
            SkillsView()
        case .agents:
            AgentsView()
        case .memory:
            MemoryView()
        case .hooks:
            HooksView()
        case .settings:
            SettingsView()
        }
    }

    private func navigateToSession(id: String) {
        Task {
            if let session = try? db.getSession(id: id) {
                await MainActor.run {
                    selectedSession = session
                }
            }
        }
    }

    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        Task {
            let query = searchQuery
            let results = (try? db.search(query: query, limit: 20)) ?? []
            await MainActor.run {
                if let first = results.first {
                    selectedSession = first
                }
            }
        }
    }

    private func resumeSelectedSession() {
        guard selectedSession != nil else { return }
        showResume = true
    }
}

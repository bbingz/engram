// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @State private var showPalette: Bool = false
    @State private var paletteItems: [PaletteItem] = []
    @State private var paletteSelection: Int = 0
    @State private var pendingNavigationId: String? = nil
    @Environment(DatabaseManager.self) var db

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
        .navigationSplitViewStyle(.balanced)
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: openPalette) {
                    Label("Command Palette", systemImage: "command")
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityIdentifier("command_palette_button")
                .help("Command Palette")
            }
        }
        .onChange(of: selectedScreen) { _, _ in
            // Clear session detail when navigating to a different page
            pendingNavigationId = nil
            selectedSession = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notification in
            if let box = notification.object as? SessionBox {
                pendingNavigationId = nil
                selectedSession = box.session
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToScreen)) { notification in
            if let rawValue = notification.object as? String,
               let screen = Screen(rawValue: rawValue) {
                selectedScreen = screen
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

    private func openPalette() {
        showPalette = true
    }

    private func navigateToSession(id: String) {
        // Detached so the SQLite lookup runs off the main thread (an unstructured
        // Task started here inherits the MainActor executor).
        pendingNavigationId = id
        let db = self.db
        Task.detached {
            guard let session = try? db.getSession(id: id) else {
                await MainActor.run {
                    if pendingNavigationId == id {
                        pendingNavigationId = nil
                    }
                }
                return
            }
            await MainActor.run {
                guard pendingNavigationId == id else { return }
                selectedSession = session
                pendingNavigationId = nil
            }
        }
    }

}

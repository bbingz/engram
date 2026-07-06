// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @State private var showPalette: Bool = false
    @State private var pendingNavigationId: String? = nil
    @State private var pendingSearchTerm: String? = nil
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedScreen: $selectedScreen)
        } detail: {
            if let session = selectedSession {
                SessionDetailView(session: session, onBack: { selectedSession = nil }, searchTerm: pendingSearchTerm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .navigationSplitViewStyle(.balanced)
        .background(Theme.background)
        .accessibilityIdentifier("main_window_content")
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
            pendingSearchTerm = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notification in
            if let box = notification.object as? SessionBox {
                pendingNavigationId = nil
                pendingSearchTerm = box.searchTerm
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
                },
                onRefreshUsage: {
                    let client = serviceClient
                    Task { _ = try? await client.refreshUsage() }
                    showPalette = false
                },
                onRegenerateTitles: {
                    let client = serviceClient
                    Task { _ = try? await client.regenerateAllTitles() }
                    showPalette = false
                }
            )
            .environment(db)
            .environment(serviceClient)
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
        case .favorites:
            FavoritesPageView()
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
        case .agents:
            AgentsView()
        case .memory:
            MemoryView()
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
        // Palette-driven opens carry no search query; don't leak a stale term
        // from a prior search-driven open into the find bar.
        pendingSearchTerm = nil
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

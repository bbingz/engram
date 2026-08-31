// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    let initialSession: SessionBox?
    let appStorage: UserDefaults
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @State private var showPalette: Bool = false
    @State private var pendingNavigationId: UUID? = nil
    @State private var pendingSearchTerm: String? = nil
    @Environment(DatabaseManager.self) var db
    @Environment(\.engramServiceClient) var serviceClient

    init(initialSession: SessionBox? = nil, appStorage: UserDefaults) {
        self.initialSession = initialSession
        self.appStorage = appStorage
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedScreen: $selectedScreen)
        } detail: {
            if let session = selectedSession {
                SessionDetailView(session: session, onBack: {
                    pendingNavigationId = nil
                    SessionNavigationGate.cancelAll()
                    pendingSearchTerm = nil
                    selectedSession = nil
                }, searchTerm: pendingSearchTerm)
                    .id(session.id)
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
            SessionNavigationGate.cancelAll()
            selectedSession = nil
            pendingSearchTerm = nil
        }
        .onAppear {
            if let initialSession {
                applyOpenSession(initialSession)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notification in
            if let box = notification.object as? SessionBox {
                applyOpenSession(box)
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
            .environment(\.engramServiceClient, serviceClient)
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
            HomeView(appStorage: appStorage)
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

    private func applyOpenSession(_ box: SessionBox) {
        guard let token = box.navigationId else {
            // Synchronous rows carry no async click token. They still cancel a
            // live resolution so its later notification cannot reopen detail.
            SessionNavigationGate.cancelAll()
            pendingNavigationId = nil
            pendingSearchTerm = box.searchTerm
            selectedSession = box.session
            return
        }
        guard SessionNavigationGate.isCurrent(token) else { return }
        pendingNavigationId = nil
        pendingSearchTerm = box.searchTerm
        selectedSession = box.session
        SessionNavigationGate.complete(token)
    }

    private func navigateToSession(id: String) {
        // Detached so the SQLite lookup runs off the main thread (an unstructured
        // Task started here inherits the MainActor executor).
        let token = SessionNavigationGate.begin()
        pendingNavigationId = token
        let db = self.db
        Task.detached {
            guard let session = try? db.getSession(id: id) else {
                await MainActor.run {
                    if pendingNavigationId == token {
                        pendingNavigationId = nil
                        SessionNavigationGate.complete(token)
                    }
                }
                return
            }
            await MainActor.run {
                guard pendingNavigationId == token,
                      SessionNavigationGate.isCurrent(token)
                else { return }
                // Clear a prior search query only after the replacement session
                // exists; a failed palette lookup must leave current detail intact.
                pendingSearchTerm = nil
                selectedSession = session
                pendingNavigationId = nil
                SessionNavigationGate.complete(token)
            }
        }
    }

}

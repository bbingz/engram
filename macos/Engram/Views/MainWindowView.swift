// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @State private var showSearch: Bool = false
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @EnvironmentObject var daemonClient: DaemonClient

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedScreen: $selectedScreen)
        } detail: {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    TopBarView(
                        showSearch: $showSearch,
                        selectedSession: selectedSession,
                        onResume: { resumeSelectedSession() }
                    )
                    Divider()

                    if let session = selectedSession {
                        VStack(spacing: 0) {
                            HStack {
                                Button(action: { selectedSession = nil }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left")
                                        Text("Back")
                                    }
                                    .font(.callout)
                                    .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            SessionDetailView(session: session)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        detailView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if showSearch {
                    GlobalSearchOverlay(isVisible: $showSearch) { sessionId in
                        navigateToSession(id: sessionId)
                    }
                    .padding(.top, 46) // below TopBarView
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.background)
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notification in
            if let box = notification.object as? SessionBox {
                selectedSession = box.session
            }
        }
        // ⌘K keyboard shortcut
        .background(
            Button("") { showSearch.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedScreen {
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

    private func resumeSelectedSession() {
        guard let session = selectedSession else { return }
        // Open Terminal and run claude resume for the session's working directory
        let cwd = session.cwd ?? "~"
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(cwd) && claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var errorDict: NSDictionary?
            appleScript.executeAndReturnError(&errorDict)
        }
    }
}

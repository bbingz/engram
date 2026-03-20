// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @State private var showSearch: Bool = false
    @State private var showResume: Bool = false
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @EnvironmentObject var daemonClient: DaemonClient

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedScreen: $selectedScreen)
        } detail: {
            ZStack(alignment: .top) {
                if let session = selectedSession {
                    SessionDetailView(session: session, onBack: { selectedSession = nil })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    detailView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if showSearch {
                    GlobalSearchOverlay(isVisible: $showSearch) { sessionId in
                        navigateToSession(id: sessionId)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack {
                    Spacer()

                    // Search button
                    Button { showSearch.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                            Text("Search sessions...")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("⌘K")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()

                    // Resume button
                    Button(action: { resumeSelectedSession() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text("Resume")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selectedSession != nil ? Color.green.opacity(0.15) : Color.secondary.opacity(0.06))
                        .foregroundStyle(selectedSession != nil ? .green : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedSession == nil)
                }
                .frame(maxWidth: .infinity)
            }
        }
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
        // ⌘K keyboard shortcut
        .background(
            Button("") { showSearch.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .sheet(isPresented: $showResume) {
            if let session = selectedSession {
                ResumeDialog(session: session)
                    .environmentObject(indexer)
            }
        }
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
        guard selectedSession != nil else { return }
        showResume = true
    }
}

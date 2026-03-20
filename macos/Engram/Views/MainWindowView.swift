// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @State private var searchQuery: String = ""
    @State private var showResume: Bool = false
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @EnvironmentObject var daemonClient: DaemonClient

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

                // Search field — flat style matching toolbar background
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search sessions…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { performSearch() }
                        .frame(minWidth: 140)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("⌘K")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))

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

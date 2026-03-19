// macos/Engram/Views/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedScreen: Screen = .home
    @State private var selectedSession: Session? = nil
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @EnvironmentObject var daemonClient: DaemonClient

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedScreen: $selectedScreen)
        } detail: {
            if let session = selectedSession {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: { selectedSession = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .font(.callout)
                            .foregroundStyle(Color(hex: 0x4A8FE7))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    SessionDetailView(session: session)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: 0x1A1D24))
            } else {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: 0x1A1D24))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notification in
            if let box = notification.object as? SessionBox {
                selectedSession = box.session
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
}


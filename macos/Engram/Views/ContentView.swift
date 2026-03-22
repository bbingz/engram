// macos/Engram/Views/ContentView.swift
import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("com.engram.openSettings")
    static let openWindow = Notification.Name("com.engram.openWindow")
    static let openSession = Notification.Name("com.engram.openSession")
    static let navigateToScreen = Notification.Name("com.engram.navigateToScreen")
}

/// Box wrapper to safely pass Swift structs through NSNotification.object
class SessionBox {
    let session: Session
    init(_ session: Session) { self.session = session }
}

enum AppTab: Int, CaseIterable {
    case sessions, search, timeline, favorites

    var label: LocalizedStringKey {
        switch self {
        case .sessions:  return "Browse"
        case .search:    return "Search"
        case .timeline:  return "Timeline"
        case .favorites: return "Favorites"
        }
    }

    var icon: String {
        switch self {
        case .sessions:  return "folder"       // Changed from list icon
        case .search:    return "magnifyingglass"
        case .timeline:  return "clock.arrow.circlepath"  // Changed from timeline.selection
        case .favorites: return "star"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @State private var selectedTab: AppTab = .sessions
    @State private var deepLinkSession: Session?

    var body: some View {
        VStack(spacing: 0) {
            // Segmented tab picker
            Picker("", selection: $selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Content
            Group {
                switch selectedTab {
                case .sessions:
                    SessionListView(deepLinkSession: $deepLinkSession)
                case .search:
                    SearchView()
                case .timeline:
                    TimelineView(selectedTab: $selectedTab, deepLinkSession: $deepLinkSession)
                case .favorites:
                    FavoritesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .openSession)) { notif in
                if let box = notif.object as? SessionBox {
                    deepLinkSession = box.session
                    selectedTab = .sessions
                }
            }

            Divider()

            // Status bar
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(indexer.status.displayString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                } label: {
                    Image(systemName: "gear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings...")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    var statusColor: Color {
        switch indexer.status {
        case .running:  return .green
        case .starting: return .yellow
        case .error:    return .red
        case .stopped:  return .gray
        }
    }
}

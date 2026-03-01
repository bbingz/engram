// macos/Engram/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @State private var selectedTab = 0
    @State private var deepLinkSession: Session?

    var body: some View {
        VStack(spacing: 0) {
            // Small top inset so the tab bar doesn't press against the popover edge
            Color.clear.frame(height: 6)
            TabView(selection: $selectedTab) {
                SessionListView(deepLinkSession: $deepLinkSession)
                    .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
                    .tag(0)
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(1)
                TimelineView(selectedTab: $selectedTab, deepLinkSession: $deepLinkSession)
                    .tabItem { Label("Timeline", systemImage: "timeline.selection") }
                    .tag(2)
                FavoritesView()
                    .tabItem { Label("Favorites", systemImage: "star") }
                    .tag(3)
            }
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(indexer.status.displayString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if #available(macOS 14.0, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
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

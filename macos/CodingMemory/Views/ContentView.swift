// macos/CodingMemory/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                SessionListView()
                    .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                TimelineView()
                    .tabItem { Label("Timeline", systemImage: "timeline.selection") }
                FavoritesView()
                    .tabItem { Label("Favorites", systemImage: "star") }
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

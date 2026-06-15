// macos/Engram/Views/Pages/FavoritesPageView.swift
import SwiftUI

struct FavoritesPageView: View {
    @Environment(DatabaseManager.self) var db
    @State private var favorites: [Session] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load favorites: \(loadError)")
                }
                SectionHeader(icon: "star", title: "Favorites")
                if isLoading && favorites.isEmpty {
                    // First-load skeleton convention: never a blank gap or zeroed card.
                    LazyVStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonRow()
                        }
                    }
                } else if favorites.isEmpty {
                    EmptyState(
                        icon: "star",
                        title: "No favorites",
                        message: "Star a session from its transcript toolbar to see it here."
                    )
                    .accessibilityIdentifier("favorites_emptyState")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(favorites.enumerated()), id: \.element.id) { index, session in
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
                            .accessibilityIdentifier("favorites_row_\(index)")
                        }
                    }
                    .accessibilityIdentifier("favorites_list")
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("favorites_container")
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        // UI-C1/C2: run the synchronous GRDB read off the main thread.
        let db = self.db
        do {
            favorites = try await Task.detached { try db.listFavorites() }.value
            loadError = nil
        } catch {
            EngramLogger.error("FavoritesView load failed", module: .ui, error: error)
            loadError = error.localizedDescription
        }
    }
}

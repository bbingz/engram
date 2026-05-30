// macos/Engram/Views/FavoritesView.swift
import SwiftUI

struct FavoritesView: View {
    @Environment(DatabaseManager.self) var db
    @State private var sessions: [Session] = []

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "star")
                } description: {
                    Text("Star sessions in the Sessions tab to see them here.")
                }
            } else {
                List(sessions) { session in
                    SessionRow(session: session)
                }
            }
        }
        .task {
            // Off the main thread: listFavorites is a sessions JOIN favorites
            // (readInBackground runs on the calling thread).
            let db = self.db
            sessions = await Task.detached { (try? db.listFavorites()) ?? [] }.value
        }
    }
}

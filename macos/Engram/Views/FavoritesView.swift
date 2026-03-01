// macos/Engram/Views/FavoritesView.swift
import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var sessions: [Session] = []

    var body: some View {
        Group {
            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No favorites yet").foregroundStyle(.secondary)
                    Text("Star sessions in the Sessions tab.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sessions) { session in
                    SessionRow(session: session)
                }
            }
        }
        .task { sessions = (try? db.listFavorites()) ?? [] }
    }
}

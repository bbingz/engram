// macos/Engram/Views/SearchView.swift
import SwiftUI

struct SearchView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var query = ""
    @State private var results: [Session] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sessions (min 3 chars)...", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)

            if results.isEmpty && query.count >= 3 {
                Text("No results for \"\(query)\"")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { session in
                    SessionRow(session: session)
                }
            }
        }
        .onChange(of: query) { _, new in
            if new.count >= 3 { search() }
            else if new.isEmpty { results = [] }
        }
    }

    func search() {
        results = (try? db.search(query: query)) ?? []
    }
}

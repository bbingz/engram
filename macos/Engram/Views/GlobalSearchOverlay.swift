// macos/Engram/Views/GlobalSearchOverlay.swift
import SwiftUI

struct GlobalSearchOverlay: View {
    @Binding var isVisible: Bool
    @Environment(IndexerProcess.self) var indexer
    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var isSearching = false
    @FocusState private var isFocused: Bool

    let onSelectSession: (String) -> Void  // session ID

    struct SearchHit: Identifiable {
        let id: String
        let title: String
        let source: String
        let snippet: String
        let date: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all sessions...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .onSubmit { performSearch() }
                    .onChange(of: query) { _, newValue in
                        if newValue.isEmpty {
                            results = []
                        }
                    }
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                Button { isVisible = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            if !results.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { hit in
                            Button {
                                onSelectSession(hit.id)
                                isVisible = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(hit.title)
                                            .font(.system(size: 13, weight: .medium))
                                        Spacer()
                                        Text(hit.date)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(hit.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.15), radius: 10)
        .padding(.horizontal, 40)
        .padding(.top, 4)
        .onAppear { isFocused = true }
    }

    func performSearch() {
        guard !query.isEmpty, let port = indexer.port else { return }
        isSearching = true
        Task {
            do {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let url = URL(string: "http://127.0.0.1:\(port)/api/search?q=\(encoded)&limit=10")!
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rawResults = json["results"] as? [[String: Any]] {
                    results = rawResults.compactMap { r in
                        guard let session = r["session"] as? [String: Any],
                              let id = session["id"] as? String else { return nil }
                        return SearchHit(
                            id: id,
                            title: (session["summary"] as? String) ?? (session["project"] as? String) ?? "Untitled",
                            source: (session["source"] as? String) ?? "",
                            snippet: (r["snippet"] as? String) ?? "",
                            date: (session["startTime"] as? String).map { String($0.prefix(10)) } ?? ""
                        )
                    }
                }
            } catch {
                // silently fail
            }
            isSearching = false
        }
    }
}

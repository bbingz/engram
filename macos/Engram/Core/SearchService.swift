// macos/Engram/Core/SearchService.swift
import Foundation

struct SearchHit: Identifiable {
    let id: String
    let title: String
    let source: String
    let snippet: String
    let date: String
}

struct SessionHit: Identifiable {
    let id: String
    let title: String
    let snippet: String
    let date: String
}

/// Shared search service — eliminates duplication between GlobalSearchOverlay and CommandPaletteView
@MainActor
final class SearchService {
    static let shared = SearchService()

    private init() {}

    func searchSessions(query: String, port: Int) async -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        do {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let url = URL(string: "http://127.0.0.1:\(port)/api/search?q=\(encoded)&limit=10")!
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawResults = json["results"] as? [[String: Any]] {
                return rawResults.compactMap { r in
                    guard let session = r["session"] as? [String: Any],
                          let id = session["id"] as? String else { return nil }
                    return SearchHit(
                        id: id,
                        title: (session["summary"] as? String) ?? (session["project"] as? String) ?? (session["generatedTitle"] as? String) ?? "Untitled",
                        source: (session["source"] as? String) ?? "",
                        snippet: (r["snippet"] as? String) ?? "",
                        date: (session["startTime"] as? String).map { String($0.prefix(10)) } ?? ""
                    )
                }
            }
        } catch {
            // silently fail — search is best-effort
        }
        return []
    }
}

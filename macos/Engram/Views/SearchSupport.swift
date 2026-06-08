import SwiftUI

enum SearchMode: String, CaseIterable {
    case hybrid, keyword, semantic

    /// Modes the product can actually serve. Semantic/hybrid require vector
    /// embeddings, so keyword remains the only visible mode without embeddings.
    static func availableModes(embeddingAvailable: Bool) -> [SearchMode] {
        embeddingAvailable ? [.hybrid, .keyword, .semantic] : [.keyword]
    }
}

struct EmbeddingStatus {
    let available: Bool
    let model: String?
    let embeddedCount: Int
    let totalSessions: Int
    let progress: Int
}

struct SearchResult: Identifiable {
    let id: String
    let session: Session?
    let snippet: String
    let matchType: String
    let score: Double
}

/// Renders FTS `<mark>...</mark>` snippets as emphasized attributed text while
/// preserving unrelated angle-bracket transcript content verbatim.
enum SnippetHighlighter {
    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.range(of: "<mark>") {
            result.append(AttributedString(String(rest[..<open.lowerBound])))
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "</mark>") else {
                result.append(AttributedString(String(afterOpen)))
                return result
            }
            var marked = AttributedString(String(afterOpen[..<close.lowerBound]))
            marked.inlinePresentationIntent = .stronglyEmphasized
            result.append(marked)
            rest = afterOpen[close.upperBound...]
        }
        result.append(AttributedString(String(rest)))
        return result
    }
}

extension EngramServiceSearchResponse.Item {
    var searchResult: SearchResult {
        let totalMessages = messageCount
            ?? [userMessageCount, assistantMessageCount, systemMessageCount, toolMessageCount]
                .compactMap(\.self)
                .reduce(0, +)
        let session = Session(
            id: id,
            source: source ?? "unknown",
            startTime: startTime ?? "",
            endTime: endTime,
            cwd: cwd ?? "",
            project: project,
            model: model,
            messageCount: totalMessages,
            userMessageCount: userMessageCount ?? 0,
            assistantMessageCount: assistantMessageCount ?? 0,
            systemMessageCount: systemMessageCount ?? 0,
            summary: summary ?? title,
            filePath: filePath ?? "",
            sourceLocator: sourceLocator,
            sizeBytes: sizeBytes ?? 0,
            indexedAt: indexedAt ?? "",
            agentRole: agentRole,
            hiddenAt: nil,
            customName: customName,
            tier: tier,
            toolMessageCount: toolMessageCount ?? 0,
            generatedTitle: generatedTitle ?? title,
            parentSessionId: parentSessionId,
            suggestedParentId: suggestedParentId,
            linkSource: linkSource,
            qualityScore: qualityScore
        )
        return SearchResult(
            id: id,
            session: session,
            snippet: snippet ?? "",
            matchType: matchType ?? "keyword",
            score: score ?? 0
        )
    }
}

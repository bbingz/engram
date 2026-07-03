import SwiftUI

struct SessionTaxonomyBadge: View {
    let tag: SessionTaxonomyTag

    var body: some View {
        Label(tag.label, systemImage: tag.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
            .help(tag.label)
            .accessibilityLabel(tag.label)
    }

    private var tint: Color {
        switch tag {
        case .subagent: Theme.accent
        case .workflow: Theme.green
        case .side: Theme.tertiaryText
        case .archived: Theme.orange
        case .orphan: Theme.red
        case .suggestedParent: Theme.tertiaryText
        }
    }
}

struct SessionTaxonomyBadges: View {
    let session: Session
    let confirmedChildCount: Int
    let suggestedChildCount: Int

    private var tags: [SessionTaxonomyTag] {
        SessionTaxonomy.tags(
            for: session,
            confirmedChildCount: confirmedChildCount,
            suggestedChildCount: suggestedChildCount
        )
    }

    var body: some View {
        ForEach(tags) { tag in
            SessionTaxonomyBadge(tag: tag)
        }
    }
}

// macos/Engram/Components/ExpandableSessionCard.swift
import SwiftUI

// MARK: - Relative time helper (shared with SessionCard)

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func relativeTime(_ iso: String) -> String {
    guard let date = isoFormatter.date(from: iso) else { return "" }
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

// MARK: - ExpandableSessionCard

struct ExpandableSessionCard: View {
    let session: Session
    let confirmedChildCount: Int
    let suggestedChildCount: Int
    var includeHiddenChildren = false
    var onTap: (() -> Void)? = nil
    var onChildTap: ((Session) -> Void)? = nil
    var onResume: ((Session) -> Void)? = nil
    var onCopyResumeCommand: ((Session) -> Void)? = nil
    var onHandoff: ((Session) -> Void)? = nil
    var onReplay: ((Session) -> Void)? = nil
    var onConfirmSuggestion: ((Session) -> Void)? = nil
    var onDismissSuggestion: ((Session) -> Void)? = nil

    @State private var isExpanded = false
    @State private var children: [Session] = []
    @State private var suggestedChildren: [Session] = []
    @State private var isLoadingChildren = false
    // In-flight guard for "show more" so rapid taps cannot append duplicates.
    @State private var isLoadingMore = false
    // Generation token: bumped whenever the child set is invalidated (count
    // change). A load result only applies if its captured generation still
    // matches, so a stale in-flight load cannot clobber a fresh reset.
    @State private var loadGeneration = 0
    @Environment(DatabaseManager.self) var db

    private var totalChildCount: Int { confirmedChildCount + suggestedChildCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Parent row
            HStack(spacing: 6) {
                // Disclosure triangle
                if totalChildCount > 0 {
                    // Button (not bare onTapGesture) so VoiceOver exposes it as a control
                    Button(action: { toggleExpand() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse agent sessions" : "Expand agent sessions")
                } else {
                    Spacer().frame(width: 14)
                }

                // Main session card content (reuses SessionCard layout inline)
                Button(action: { onTap?() }) {
                    HStack(spacing: 10) {
                        SourcePill(source: session.source)

                        Text(session.displayTitle)
                            .font(.callout)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        if let project = session.project {
                            ProjectBadge(project: project, source: session.source)
                        }

                        // Child count badge
                        if totalChildCount > 0 {
                            childCountBadge
                        }

                        Text("\(session.messageCount) msgs")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)

                        Text(relativeTime(session.endTime ?? session.startTime))
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 40, alignment: .trailing)

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText.opacity(0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Resume...") {
                        onResume?(session)
                    }
                    Button("Copy Resume Command") {
                        onCopyResumeCommand?(session)
                    }
                    Button("Handoff") {
                        onHandoff?(session)
                    }
                    Button("Replay") {
                        onReplay?(session)
                    }
                }
            }

            // Expanded children
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if isLoadingChildren {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.6)
                                .padding(.vertical, 4)
                            Spacer()
                        }
                    } else {
                        // Confirmed children
                        ForEach(children) { child in
                            CompactChildRow(
                                session: child,
                                isConfirmed: true,
                                onTap: { onChildTap?(child) },
                                onResume: { onResume?(child) },
                                onCopyResumeCommand: { onCopyResumeCommand?(child) },
                                onHandoff: { onHandoff?(child) },
                                onReplay: { onReplay?(child) }
                            )
                        }

                        // "show N more..." for confirmed children
                        if confirmedChildCount > children.count && !children.isEmpty {
                            Button {
                                loadMoreChildren()
                            } label: {
                                Text("show \(confirmedChildCount - children.count) more...")
                                    .font(.caption)
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 28)
                            .padding(.vertical, 4)
                        }

                        // Suggested children
                        ForEach(suggestedChildren) { child in
                            CompactChildRow(
                                session: child,
                                isConfirmed: false,
                                onTap: { onChildTap?(child) },
                                onResume: { onResume?(child) },
                                onCopyResumeCommand: { onCopyResumeCommand?(child) },
                                onHandoff: { onHandoff?(child) },
                                onReplay: { onReplay?(child) },
                                onConfirm: { onConfirmSuggestion?(child) },
                                onDismiss: { onDismissSuggestion?(child) }
                            )
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 2)
            }
        }
        .onChange(of: [confirmedChildCount, suggestedChildCount]) {
            // Invalidate on EITHER count changing, not just their sum — a
            // confirmed/suggested swap that preserves the total must still reload.
            // Bump the generation so any in-flight load/loadMore is discarded.
            loadGeneration += 1
            children = []
            suggestedChildren = []
            isLoadingMore = false
            if isExpanded {
                loadChildren()
            }
        }
    }

    // MARK: - Child count badge

    @ViewBuilder
    private var childCountBadge: some View {
        if confirmedChildCount > 0 {
            Text("\(confirmedChildCount) agent\(confirmedChildCount == 1 ? "" : "s")")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.accent.opacity(0.15))
                .foregroundStyle(Theme.accent)
                .clipShape(Capsule())
        } else if suggestedChildCount > 0 {
            Text("~\(suggestedChildCount) suggested")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.surfaceHighlight)
                .foregroundStyle(Theme.tertiaryText)
                .clipShape(Capsule())
        }
    }

    // MARK: - Loading

    private func toggleExpand() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isExpanded.toggle()
        }
        if isExpanded && children.isEmpty && suggestedChildren.isEmpty {
            loadChildren()
        }
    }

    private func loadChildren() {
        isLoadingChildren = true
        let generation = loadGeneration
        Task.detached { [db, session, includeHiddenChildren] in
            let confirmed = (try? db.childSessions(
                parentId: session.id,
                includeHidden: includeHiddenChildren,
                limit: 5
            )) ?? []
            let suggested = (try? db.suggestedChildSessions(
                parentId: session.id,
                includeHidden: includeHiddenChildren
            )) ?? []
            await MainActor.run {
                // Drop stale results from a generation that was invalidated.
                guard generation == loadGeneration else { return }
                children = confirmed
                suggestedChildren = suggested
                isLoadingChildren = false
            }
        }
    }

    private func loadMoreChildren() {
        // Coalesce rapid taps: ignore while a "show more" load is in flight.
        guard !isLoadingMore else { return }
        isLoadingMore = true
        let generation = loadGeneration
        let currentCount = children.count
        Task.detached { [db, session, includeHiddenChildren] in
            let more = (try? db.childSessions(
                parentId: session.id,
                includeHidden: includeHiddenChildren,
                limit: 20,
                offset: currentCount
            )) ?? []
            await MainActor.run {
                defer { isLoadingMore = false }
                // Drop stale results from a generation that was invalidated.
                guard generation == loadGeneration else { return }
                // De-dup on append in case offsets overlap or a reload raced.
                let existing = Set(children.map(\.id))
                children.append(contentsOf: more.filter { !existing.contains($0.id) })
            }
        }
    }
}

// MARK: - CompactChildRow

struct CompactChildRow: View {
    let session: Session
    let isConfirmed: Bool
    var onTap: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    var onCopyResumeCommand: (() -> Void)? = nil
    var onHandoff: (() -> Void)? = nil
    var onReplay: (() -> Void)? = nil
    var onConfirm: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            SourcePill(source: session.source)
                .scaleEffect(0.85)

            Text(session.displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isConfirmed ? Theme.primaryText : Theme.tertiaryText)

            Spacer()

            if !isConfirmed {
                Button("Confirm") { onConfirm?() }
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)

                Button("\u{00D7}") { onDismiss?() }
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .buttonStyle(.plain)
            }

            Text(relativeTime(session.endTime ?? session.startTime))
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isConfirmed ? Color.clear : Theme.surface.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isConfirmed ? Color.clear : Theme.border.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .contextMenu {
            Button("Resume...") {
                onResume?()
            }
            Button("Copy Resume Command") {
                onCopyResumeCommand?()
            }
            Button("Handoff") {
                onHandoff?()
            }
            Button("Replay") {
                onReplay?()
            }
        }
    }
}

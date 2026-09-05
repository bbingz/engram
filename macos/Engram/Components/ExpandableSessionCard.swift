// macos/Engram/Components/ExpandableSessionCard.swift
import SwiftUI

private func relativeTime(_ iso: String) -> String {
    RelativeTimeText.format(iso, style: .compact)
}

// MARK: - ExpandableSessionCard

struct ExpandableSessionCard: View {
    /// Remote-snapshot action capability (merge-gate fix; design §9). The menu
    /// keys every action off this table instead of the raw property:
    /// - Resume/Copy/Handoff need the session live on this machine → remote off.
    /// - Replay stays ON: replayTimeline falls back to the indexed FTS timeline
    ///   when the locator is remote:// (EngramServiceReadProvider step 3), and
    ///   the detail page offers it too.
    /// - Export reads the real transcript file via TranscriptExportService, so
    ///   a remote:// locator would fail mid-export → remote off.
    static func canResumeLocally(_ session: Session) -> Bool { !session.isRemoteSnapshot }
    static func canReplay(_ session: Session) -> Bool { true }
    static func canExport(_ session: Session) -> Bool { !session.isRemoteSnapshot }

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
    var onRelate: ((Session) -> Void)? = nil
    var onHide: ((Session) -> Void)? = nil
    var onRename: ((Session) -> Void)? = nil
    var onExportMarkdown: ((Session) -> Void)? = nil
    var onExportJSON: ((Session) -> Void)? = nil
    var exportsDisabled = false
    /// Favorite toggle with a main-actor success flag.
    /// Callers invoke `completion(true)` after a successful service write/reload
    /// and `completion(false)` on failure. Parent/Timeline sites may ignore it;
    /// expanded child rows apply local `isFavorite` only on `true`.
    var onToggleFavorite: ((Session, @escaping @MainActor (Bool) -> Void) -> Void)? = nil
    var isHidden = false

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var totalChildCount: Int { confirmedChildCount + suggestedChildCount }

    /// Pure local update for expanded-child favorite membership after a toggle.
    /// Child rows live in `@State` and are only annotated from `listFavorites` at
    /// load, so without this the menu target cannot reverse until re-expand.
    /// Updates confirmed and suggested arrays by session id (no-op if absent).
    static func applyingChildFavorite(
        confirmed: [Session],
        suggested: [Session],
        sessionId: String,
        isFavorite: Bool
    ) -> (confirmed: [Session], suggested: [Session]) {
        func mark(_ sessions: [Session]) -> [Session] {
            sessions.map { session in
                guard session.id == sessionId else { return session }
                var copy = session
                copy.isFavorite = isFavorite
                return copy
            }
        }
        return (mark(confirmed), mark(suggested))
    }

    /// Completion-aware local child update: flip only when the service reports
    /// success. Failure leaves both arrays and `favoriteToggleTarget` unchanged.
    /// `preToggleSession` must be the pre-service session so the target is
    /// `preToggleSession.favoriteToggleTarget` (symmetric `!isFavorite`).
    static func applyingChildFavoriteIfSucceeded(
        confirmed: [Session],
        suggested: [Session],
        preToggleSession: Session,
        success: Bool
    ) -> (confirmed: [Session], suggested: [Session]) {
        guard success else { return (confirmed, suggested) }
        return applyingChildFavorite(
            confirmed: confirmed,
            suggested: suggested,
            sessionId: preToggleSession.id,
            isFavorite: preToggleSession.favoriteToggleTarget
        )
    }

    /// Invoke the page callback with the pre-toggle child session; apply local
    /// confirmed/suggested `isFavorite` only when completion reports success.
    private func toggleChildFavorite(_ child: Session) {
        // Pre-toggle session preserves favoriteToggleTarget for the service write.
        onToggleFavorite?(child) { success in
            let updated = Self.applyingChildFavoriteIfSucceeded(
                confirmed: children,
                suggested: suggestedChildren,
                preToggleSession: child,
                success: success
            )
            children = updated.confirmed
            suggestedChildren = updated.suggested
        }
    }

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
                        OriginBadge(origin: session.origin)

                        Text(session.displayTitle)
                            .font(.callout)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        if let project = session.project {
                            ProjectBadge(project: project, source: session.source)
                        }

                        // Human-driven cue: number of distinct asks (≥2).
                        if let asks = session.instructionCount, asks >= 2 {
                            Text("\(asks) asks")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                                .accessibilityIdentifier("expandableCard_askCount")
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
                    .padding(.vertical, Theme.listRowVerticalPadding)
                    .background(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    // Remote/HQ-snapshot rows cannot be resumed locally (design
                    // §9): the card has no local transcript file. Disable with a
                    // reason rather than drop so the menu stays spatially stable.
                    Button("Resume...") {
                        onResume?(session)
                    }
                    .disabled(!ExpandableSessionCard.canResumeLocally(session))
                    .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Resume this session in a terminal")
                    Button("Copy Resume Command") {
                        onCopyResumeCommand?(session)
                    }
                    .disabled(!ExpandableSessionCard.canResumeLocally(session))
                    .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Copy the resume command to the clipboard")
                    Button("Handoff") {
                        onHandoff?(session)
                    }
                    .disabled(!ExpandableSessionCard.canResumeLocally(session))
                    .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Hand off to another tool")
                    // Replay stays enabled for remote snapshots: the service
                    // falls back to the indexed FTS timeline (canReplay).
                    Button("Replay") {
                        onReplay?(session)
                    }
                    .help("Replay this session")
                    if let onRelate {
                        Button("Link related session…") {
                            onRelate(session)
                        }
                    }
                    SessionWriteMenuItems(
                        isHidden: isHidden,
                        isFavorite: session.isFavorite,
                        // Parent list reloads on success; ignore completion here.
                        onToggleFavorite: onToggleFavorite.map { cb in
                            { cb(session) { _ in } }
                        },
                        onRename: onRename.map { cb in { cb(session) } },
                        onExportMarkdown: onExportMarkdown.map { cb in { cb(session) } },
                        onExportJSON: onExportJSON.map { cb in { cb(session) } },
                        exportsDisabled: exportsDisabled,
                        exportAllowed: ExpandableSessionCard.canExport(session),
                        onHide: onHide.map { cb in { cb(session) } }
                    )
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
                                onReplay: { onReplay?(child) },
                                onHide: onHide.map { cb in { cb(child) } },
                                onRename: onRename.map { cb in { cb(child) } },
                                onExportMarkdown: onExportMarkdown.map { cb in { cb(child) } },
                                onExportJSON: onExportJSON.map { cb in { cb(child) } },
                                exportsDisabled: exportsDisabled,
                                // Completion-aware: local isFavorite flips only after service success.
                                onToggleFavorite: onToggleFavorite.map { _ in { toggleChildFavorite(child) } },
                                isHidden: child.hiddenAt != nil
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
                                onDismiss: { onDismissSuggestion?(child) },
                                onHide: onHide.map { cb in { cb(child) } },
                                onRename: onRename.map { cb in { cb(child) } },
                                onExportMarkdown: onExportMarkdown.map { cb in { cb(child) } },
                                onExportJSON: onExportJSON.map { cb in { cb(child) } },
                                exportsDisabled: exportsDisabled,
                                // Completion-aware: local isFavorite flips only after service success.
                                onToggleFavorite: onToggleFavorite.map { _ in { toggleChildFavorite(child) } },
                                isHidden: child.hiddenAt != nil
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
        MotionAware.animate(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
            isExpanded.toggle()
        }
        if isExpanded && children.isEmpty && suggestedChildren.isEmpty {
            loadChildren()
        }
        // VoiceOver: the chevron swap alone is silent — announce the new state.
        AccessibilityNotification.Announcement(
            isExpanded ? "Expanded, \(totalChildCount) agent sessions" : "Collapsed agent sessions"
        ).post()
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
            // Child rows can be skip-tier by design. Use raw favorites membership
            // so a starred child can still be unstarred after re-expanding it.
            let favoriteIds = Set((try? db.favoriteIds()) ?? [])
            let annotatedConfirmed = Session.applyingFavoriteIds(confirmed, favoriteIds: favoriteIds)
            let annotatedSuggested = Session.applyingFavoriteIds(suggested, favoriteIds: favoriteIds)
            await MainActor.run {
                // Drop stale results from a generation that was invalidated.
                guard generation == loadGeneration else { return }
                children = annotatedConfirmed
                suggestedChildren = annotatedSuggested
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
            let favoriteIds = Set((try? db.favoriteIds()) ?? [])
            let annotated = Session.applyingFavoriteIds(more, favoriteIds: favoriteIds)
            await MainActor.run {
                defer { isLoadingMore = false }
                // Drop stale results from a generation that was invalidated.
                guard generation == loadGeneration else { return }
                // De-dup on append in case offsets overlap or a reload raced.
                let existing = Set(children.map(\.id))
                children.append(contentsOf: annotated.filter { !existing.contains($0.id) })
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
    var onHide: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onExportMarkdown: (() -> Void)? = nil
    var onExportJSON: (() -> Void)? = nil
    var exportsDisabled = false
    var onToggleFavorite: (() -> Void)? = nil
    var isHidden = false

    /// Per-row keyboard focus (Wave 8-4): child rows were tap-gesture-only, so
    /// an expanded child was unreachable from the keyboard.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            SourcePill(source: session.source)
                .scaleEffect(0.85)
            OriginBadge(origin: session.origin)

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
                    .accessibilityLabel("Dismiss suggestion")
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
        // Keyboard activation (Wave 8-4). Rows rendered without a tap action
        // stay out of the tab order instead of becoming dead stops.
        .focusable(onTap != nil)
        .focused($isFocused)
        .onKeyPress(keys: [.return, .space]) { _ in
            guard isFocused, let onTap else { return .ignored }
            onTap()
            return .handled
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.accent, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
        .contextMenu {
            // Same remote-snapshot guard as the parent card menu (design §9).
            Button("Resume...") {
                onResume?()
            }
            .disabled(!ExpandableSessionCard.canResumeLocally(session))
            .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Resume this session in a terminal")
            Button("Copy Resume Command") {
                onCopyResumeCommand?()
            }
            .disabled(!ExpandableSessionCard.canResumeLocally(session))
            .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Copy the resume command to the clipboard")
            Button("Handoff") {
                onHandoff?()
            }
            .disabled(!ExpandableSessionCard.canResumeLocally(session))
            .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Hand off to another tool")
            // Replay stays enabled for remote snapshots: the service falls
            // back to the indexed FTS timeline (canReplay).
            Button("Replay") {
                onReplay?()
            }
            .help("Replay this session")
            SessionWriteMenuItems(
                isHidden: isHidden,
                isFavorite: session.isFavorite,
                onToggleFavorite: onToggleFavorite,
                onRename: onRename,
                onExportMarkdown: onExportMarkdown,
                onExportJSON: onExportJSON,
                exportsDisabled: exportsDisabled,
                exportAllowed: ExpandableSessionCard.canExport(session),
                onHide: onHide
            )
        }
    }
}

// MARK: - Shared write-action menu items

/// Favorite / Rename / Export / Hide menu items shared by the parent card and
/// child rows. Each item renders only when its closure is non-nil, so callers
/// that pass none (e.g. SessionDetailView child rows) get an unchanged menu.
private struct SessionWriteMenuItems: View {
    let isHidden: Bool
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onExportMarkdown: (() -> Void)? = nil
    var onExportJSON: (() -> Void)? = nil
    var exportsDisabled = false
    /// Remote-snapshot export capability (merge-gate fix): exportSession reads
    /// the real transcript file, which a remote:// row does not have.
    var exportAllowed = true
    var onHide: (() -> Void)? = nil

    private var hasAny: Bool {
        onToggleFavorite != nil || onRename != nil
            || onExportMarkdown != nil || onExportJSON != nil || onHide != nil
    }

    var body: some View {
        if hasAny {
            Divider()
            if let onToggleFavorite {
                // M19: label reflects current favorite membership (Add vs Remove).
                Button(Session.favoriteMenuLabel(isFavorite: isFavorite)) {
                    onToggleFavorite()
                }
                .accessibilityLabel(Session.favoriteAccessibilityLabel(isFavorite: isFavorite))
            }
            if let onRename {
                Button("Rename…") { onRename() }
            }
            if onExportMarkdown != nil || onExportJSON != nil {
                Menu("Export") {
                    if let onExportMarkdown {
                        Button("Markdown") { onExportMarkdown() }
                    }
                    if let onExportJSON {
                        Button("JSON") { onExportJSON() }
                    }
                }
                .disabled(exportsDisabled || !exportAllowed)
                .help(exportAllowed
                    ? "Export this session"
                    : "Export needs the local transcript file; remote snapshots only carry indexed content")
            }
            if let onHide {
                Button(isHidden ? "Unhide" : "Hide") { onHide() }
            }
        }
    }
}

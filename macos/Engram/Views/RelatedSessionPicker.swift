// macos/Engram/Views/RelatedSessionPicker.swift
import SwiftUI

/// Pick any session to link as a symmetric, untyped "related" association to
/// `source` (the only app UI caller of EngramServiceClient.addSessionRelation).
/// Presented from SessionDetailView's "Related sessions" section and from the
/// session-list card context menu. Mirrors LinkParentPicker's layout but loosens
/// the top-level-only filter — any session can be related — and excludes the
/// current session plus already-related ones from candidates.
struct RelatedSessionPicker: View {
    let source: Session
    let onLinked: () -> Void

    @Environment(DatabaseManager.self) private var db
    @Environment(\.engramServiceClient) private var serviceClient
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [Session] = []
    @State private var query = ""
    @State private var selectedId: String? = nil
    @State private var isLoading = true
    @State private var isLinking = false
    @State private var errorText: String? = nil
    @State private var loadGeneration = UUID()

    private var filtered: [Session] {
        candidates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link related session")
                .font(.headline)
            Text(source.displayTitle)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)

            TextField("Search sessions", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("relatedSession_search")

            if isLoading {
                HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
                    .frame(height: 120)
            } else if filtered.isEmpty {
                Text("No candidate sessions")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { candidate in
                            Button {
                                selectedId = candidate.id
                            } label: {
                                HStack(spacing: 8) {
                                    SourcePill(source: candidate.source)
                                    Text(candidate.displayTitle)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(Theme.primaryText)
                                    Spacer()
                                    if selectedId == candidate.id {
                                        Image(systemName: "checkmark")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(selectedId == candidate.id ? Theme.surfaceHighlight : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 200)
                .accessibilityIdentifier("relatedSession_list")
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Link") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedId == nil || isLinking)
                if isLinking {
                    ProgressView().scaleEffect(0.6)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .task(id: query) { await loadCandidates(query: query) }
    }

    private func loadCandidates(query: String) async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }
        let db = self.db
        let sourceId = source.id
        // Read candidates off the main thread (UI-C1/C2). Any session can be a
        // candidate, so unlike LinkParentPicker we do not restrict to top-level.
        do {
            let relatedIds = try await serviceClient.relatedSessions(sessionId: sourceId)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            let excluded = Set(relatedIds).union([sourceId])
            let loaded = try await Task.detached {
                try db.sessionPickerCandidates(
                    query: query,
                    topLevelOnly: false,
                    excluding: excluded,
                    limit: 200
                )
            }.value
            guard !Task.isCancelled, generation == loadGeneration else { return }
            candidates = loaded
            errorText = nil
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            candidates = []
            errorText = ServiceErrorPresenter.displayMessage(for: error)
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }

    private func link() {
        guard let targetId = selectedId else { return }
        isLinking = true
        errorText = nil
        Task {
            defer { isLinking = false }
            do {
                let response = try await serviceClient.addSessionRelation(
                    aId: source.id,
                    bId: targetId
                )
                if response.ok {
                    onLinked()
                    dismiss()
                } else {
                    errorText = response.error ?? "Failed to link session"
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

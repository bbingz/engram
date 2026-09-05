// macos/Engram/Views/LinkParentPicker.swift
import SwiftUI

/// Manual Layer-3 parent link sheet (the first and only app UI caller of
/// EngramServiceClient.setParentSession). Presented from a pending-suggestion
/// row in AgentsView: pick a candidate top-level parent for `child`, confirm,
/// and the service re-associates the session under it.
struct LinkParentPicker: View {
    let child: Session
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
            Text("Set parent")
                .font(.headline)
            Text(child.displayTitle)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)

            TextField("Search parent sessions", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("linkParent_search")

            if isLoading {
                HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
                    .frame(height: 120)
            } else if filtered.isEmpty {
                Text("No candidate parents")
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
                .accessibilityIdentifier("linkParent_list")
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
            guard !Task.isCancelled, generation == loadGeneration else { return }
        }
        let db = self.db
        let childId = child.id
        // Read candidate parents off the main thread (UI-C1/C2).
        do {
            let loaded = try await Task.detached {
                try db.sessionPickerCandidates(
                    query: query,
                    topLevelOnly: true,
                    excluding: [childId],
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
        guard let parentId = selectedId else { return }
        isLinking = true
        errorText = nil
        Task {
            defer { isLinking = false }
            do {
                let response = try await serviceClient.setParentSession(
                    sessionId: child.id,
                    parentId: parentId
                )
                if response.ok {
                    onLinked()
                    dismiss()
                } else {
                    errorText = response.error ?? "Failed to set parent"
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

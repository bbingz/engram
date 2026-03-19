// macos/Engram/Views/SessionList/ProjectSearchField.swift
import SwiftUI

/// 3-state project filter: idle button -> search field with dropdown -> selected pill.
struct ProjectSearchField: View {
    let allProjects: [(name: String, count: Int)]
    @Binding var selectedProject: String?

    @State private var isSearching = false
    @State private var query = ""
    @State private var highlightIndex = 0
    @FocusState private var isFocused: Bool

    private var filtered: [(name: String, count: Int)] {
        guard !query.isEmpty else { return allProjects }
        let q = query.lowercased()
        return allProjects.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        if let project = selectedProject {
            // State 3: selected pill
            selectedPill(project)
        } else if isSearching {
            // State 2: search field + dropdown
            searchField
        } else {
            // State 1: idle button
            idleButton
        }
    }

    // MARK: - State 1: Idle

    private var idleButton: some View {
        Button {
            isSearching = true
            query = ""
            highlightIndex = 0
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.badge.questionmark")
                Text("Project...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - State 2: Search

    private var searchField: some View {
        VStack(alignment: .trailing, spacing: 0) {
            TextField("Search project...", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 160)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onKeyPress(.upArrow) {
                    highlightIndex = max(0, highlightIndex - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    highlightIndex = min(filtered.count - 1, highlightIndex + 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    if !filtered.isEmpty, highlightIndex < filtered.count {
                        select(filtered[highlightIndex].name)
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        // Small delay to allow click on dropdown item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if !isFocused { dismiss() }
                        }
                    }
                }

            if !filtered.isEmpty {
                dropdown
            }
        }
    }

    private var dropdown: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filtered.prefix(12).enumerated()), id: \.element.name) { idx, item in
                    Button {
                        select(item.name)
                    } label: {
                        HStack {
                            Text(item.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.count)")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(idx == highlightIndex
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 180)
        .frame(width: 200)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - State 3: Selected pill

    private func selectedPill(_ project: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.caption2)
            Text(project)
                .font(.caption)
                .lineLimit(1)
            Button {
                selectedProject = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
    }

    // MARK: - Helpers

    private func select(_ name: String) {
        selectedProject = name
        isSearching = false
        query = ""
    }

    private func dismiss() {
        isSearching = false
        query = ""
    }
}

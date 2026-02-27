// macos/CodingMemory/Views/TimelineView.swift
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var entries: [TimelineEntry] = []
    @State private var filterText = ""

    var filtered: [TimelineEntry] {
        guard !filterText.isEmpty else { return entries }
        return entries.filter { ($0.project ?? "").localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter by project...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(filtered, id: \.project) { entry in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(entry.project ?? "(unknown)")
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(entry.sessionCount)")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                    Text(String(entry.lastUpdated.prefix(10)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task { entries = (try? db.projectTimeline()) ?? [] }
    }
}

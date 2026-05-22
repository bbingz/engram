// macos/Engram/Views/Pages/AgentsView.swift
import SwiftUI

struct AgentsView: View {
    @Environment(DatabaseManager.self) var db
    @State private var agentSessions: [Session] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    private var activeCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = ISO8601DateFormatter()
        return Set(agentSessions.filter { s in
            formatter.date(from: s.startTime).map { $0 > weekAgo } ?? false
        }.compactMap(\.agentRole)).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load agent sessions: \(loadError)")
                }
                HStack(spacing: 12) {
                    KPICard(value: "\(agentSessions.count)", label: "Agent Sessions")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                }
                SectionHeader(icon: "cpu", title: "Agent Sessions")
                if agentSessions.isEmpty && !isLoading {
                    EmptyState(icon: "cpu", title: "No agent sessions", message: "Agent sessions (subagents, dispatched tasks) will appear here")
                        .accessibilityIdentifier("agents_emptyState")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(agentSessions) { session in
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
                        }
                    }
                    .accessibilityIdentifier("agents_list")
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("agents_container")
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        // UI-C1/C2: run the synchronous GRDB read off the main thread.
        let db = self.db
        do {
            agentSessions = try await Task.detached { try db.listSessions(subAgent: true, limit: 200) }.value
            loadError = nil
        } catch {
            EngramLogger.error("AgentsView load failed", module: .ui, error: error)
            loadError = error.localizedDescription
        }
    }
}

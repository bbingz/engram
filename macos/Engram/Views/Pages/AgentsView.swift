// macos/Engram/Views/Pages/AgentsView.swift
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var agentSessions: [Session] = []
    @State private var isLoading = true

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
                HStack(spacing: 12) {
                    KPICard(value: "\(agentSessions.count)", label: "Agent Sessions")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                }
                SectionHeader(icon: "cpu", title: "Agent Sessions")
                if agentSessions.isEmpty && !isLoading {
                    EmptyState(icon: "cpu", title: "No agent sessions", message: "Agent sessions (subagents, dispatched tasks) will appear here")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(agentSessions) { session in
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do { agentSessions = try db.listSessions(subAgent: true, limit: 200) } catch { print("AgentsView error:", error) }
    }
}

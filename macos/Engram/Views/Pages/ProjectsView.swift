// macos/Engram/Views/Pages/ProjectsView.swift
import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var projectGroups: [DatabaseManager.ProjectGroup] = []
    @State private var selectedProject: DatabaseManager.ProjectGroup? = nil
    @State private var isLoading = true

    private var activeCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = ISO8601DateFormatter()
        return projectGroups.filter { group in
            guard let date = formatter.date(from: group.lastActive) else { return false }
            return date > weekAgo
        }.count
    }

    private var avgSessions: Int {
        guard !projectGroups.isEmpty else { return 0 }
        return projectGroups.reduce(0) { $0 + $1.sessionCount } / projectGroups.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(projectGroups.count)", label: "Total Projects")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                    KPICard(value: "\(avgSessions)", label: "Avg Sessions")
                }

                if let selected = selectedProject {
                    HStack {
                        Button(action: { selectedProject = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("All Projects")
                            }
                            .font(.callout)
                            .foregroundStyle(Color(hex: 0x4A8FE7))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    SectionHeader(icon: "folder", title: selected.project)
                    ForEach(selected.sessions) { session in
                        SessionCard(session: session) {
                            NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                        }
                    }
                } else {
                    SectionHeader(icon: "folder", title: "Projects")
                    if projectGroups.isEmpty && !isLoading {
                        EmptyState(icon: "folder", title: "No projects", message: "Sessions without project associations won't appear here")
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(projectGroups) { group in
                                Button(action: { selectedProject = group }) {
                                    HStack {
                                        Text(group.project.split(separator: "/").last.map(String.init) ?? group.project)
                                            .font(.callout)
                                            .foregroundStyle(.white)
                                        Text(group.project)
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: 0x6E7078))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(group.sessionCount)")
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: 0xA0A1A8))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.06))
                                            .clipShape(Capsule())
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(Color(hex: 0x6E7078).opacity(0.5))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.02))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.04), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
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
        do { projectGroups = try db.listSessionsByProject() } catch { print("ProjectsView error:", error) }
    }
}

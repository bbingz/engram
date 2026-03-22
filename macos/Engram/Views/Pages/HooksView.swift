// macos/Engram/Views/Pages/HooksView.swift
import SwiftUI

struct HooksView: View {
    @EnvironmentObject var daemonClient: DaemonClient
    @State private var hooks: [HookInfo] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    private var globalHooks: [HookInfo] { hooks.filter { $0.scope == "global" } }
    private var projectHooks: [HookInfo] { hooks.filter { $0.scope == "project" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error { AlertBanner(message: error) }
                if !globalHooks.isEmpty {
                    SectionHeader(icon: "globe", title: "Global Hooks")
                    ForEach(globalHooks) { hook in hookRow(hook) }
                }
                if !projectHooks.isEmpty {
                    SectionHeader(icon: "folder", title: "Project Hooks")
                    ForEach(projectHooks) { hook in hookRow(hook) }
                }
                if hooks.isEmpty && !isLoading {
                    EmptyState(icon: "link", title: "No hooks configured", message: "Hooks from ~/.claude/settings.json will appear here")
                        .accessibilityIdentifier("hooks_emptyState")
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("hooks_list")
        .task { await loadData() }
    }

    private func hookRow(_ hook: HookInfo) -> some View {
        HStack(spacing: 12) {
            Text(hook.event)
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.accent.opacity(0.15))
                .foregroundStyle(Theme.accent)
                .clipShape(Capsule())
            Text(hook.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
            Spacer()
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { hooks = try await daemonClient.fetch("/api/hooks") }
        catch { self.error = "Could not load hooks: \(error.localizedDescription)" }
    }
}

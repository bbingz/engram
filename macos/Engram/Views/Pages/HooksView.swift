// macos/Engram/Views/Pages/HooksView.swift
import AppKit
import SwiftUI

struct HooksView: View {
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var hooks: [EngramServiceHookInfo] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    private var globalHooks: [EngramServiceHookInfo] { hooks.filter { $0.scope == "global" } }
    private var projectHooks: [EngramServiceHookInfo] { hooks.filter { $0.scope == "project" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Spacer()
                    Button { Task { await loadData() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityIdentifier("hooks_refresh")
                }
                if let error { AlertBanner(message: error) }
                if isLoading && hooks.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
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
            .accessibilityIdentifier("hooks_list")
        }
        .refreshable { await loadData() }
        .task { await loadData() }
    }

    private func hookRow(_ hook: EngramServiceHookInfo) -> some View {
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
        .contentShape(Rectangle())
        .contextMenu {
            if let path = hook.path, !path.isEmpty {
                Button { revealInFinder(path) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { openFile(path) } label: { Label("Open Settings File", systemImage: "doc.text") }
            }
        }
    }

    private func revealInFinder(_ path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        NSWorkspace.shared.selectFile(expanded, inFileViewerRootedAtPath: "")
    }

    private func openFile(_ path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { hooks = try await serviceClient.hooks() }
        catch { self.error = "Could not load hooks: \(error.localizedDescription)" }
    }
}

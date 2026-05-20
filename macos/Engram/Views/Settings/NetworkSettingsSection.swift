// macos/Engram/Views/Settings/NetworkSettingsSection.swift
import SwiftUI

struct NetworkSettingsSection: View {
    // MCP service single-writer policy. The legacy Node daemon rollback path
    // still exists during Stage 3, but Swift service IPC is the primary writer.
    @State private var mcpStrictSingleWriter: Bool = false

    @State private var isLoadingSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "network", title: "Network")

            GroupBox("Sync") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync is not implemented in the Swift service.")
                        .font(.caption)
                    Text("Existing peer-sync keys in ~/.engram/settings.json are retained for legacy compatibility, but the macOS app does not enable or trigger sync until the native service implementation exists.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            // MCP single-writer policy. When ON, MCP write tools fail fast if
            // the Swift service is unreachable instead of falling back to a
            // direct DB write. Default OFF preserves Stage 3 rollback behavior.
            GroupBox("MCP") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Strict single writer", isOn: $mcpStrictSingleWriter)
                        .onChange(of: mcpStrictSingleWriter) { saveMcpSettings() }
                    Text("When on, MCP write tools (save_insight, project_move, …) fail if the Swift service can't be reached, instead of falling back to a direct DB write. Reduces lock contention to zero; requires the service IPC socket. Takes effect on the next Swift MCP spawn.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            loadMcpSettings()
        }
    }

    private func loadMcpSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        guard let settings = readEngramSettings() else { return }
        if let strict = settings["mcpStrictSingleWriter"] as? Bool { mcpStrictSingleWriter = strict }
    }

    private func saveMcpSettings() {
        guard !isLoadingSettings else { return }
        mutateEngramSettings { settings in
            settings["mcpStrictSingleWriter"] = mcpStrictSingleWriter
        }
    }
}

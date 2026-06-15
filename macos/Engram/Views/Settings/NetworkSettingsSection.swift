// macos/Engram/Views/Settings/NetworkSettingsSection.swift
import SwiftUI

struct NetworkSettingsSection: View {
    @State private var webUIEnabled: Bool = false

    @State private var isLoadingSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "network", title: "Network")

            GroupBox("Web UI") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable Web UI", isOn: $webUIEnabled)
                        .onChange(of: webUIEnabled) { saveNetworkSettings() }
                    Text("Serves the browser session viewer on 127.0.0.1:3457. Takes effect after the Swift service restarts.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

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
        }
        .onAppear {
            loadNetworkSettings()
        }
    }

    private func loadNetworkSettings() {
        isLoadingSettings = true
        defer { clearLoadingSettingsAfterViewUpdate() }
        guard let settings = readEngramSettings() else { return }
        if let enabled = settings["webUIEnabled"] as? Bool { webUIEnabled = enabled }
    }

    private func clearLoadingSettingsAfterViewUpdate() {
        Task { @MainActor in
            await Task.yield()
            isLoadingSettings = false
        }
    }

    private func saveNetworkSettings() {
        guard !isLoadingSettings else { return }
        mutateEngramSettings { settings in
            settings["webUIEnabled"] = webUIEnabled
        }
    }
}

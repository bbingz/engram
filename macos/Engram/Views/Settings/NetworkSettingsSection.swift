// macos/Engram/Views/Settings/NetworkSettingsSection.swift
import SwiftUI

struct NetworkSettingsSection: View {
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
        }
    }
}

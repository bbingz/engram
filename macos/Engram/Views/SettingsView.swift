// macos/Engram/Views/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GeneralSettingsSection()
                    .accessibilityIdentifier("settings_section_general")
                AISettingsSection()
                    .accessibilityIdentifier("settings_section_ai")
                SourcesSettingsSection()
                    .accessibilityIdentifier("settings_section_sources")
                NetworkSettingsSection()
                    .accessibilityIdentifier("settings_section_network")
                AboutSettingsSection()
                    .accessibilityIdentifier("settings_section_about")
            }
            .padding(24)
        }
        .accessibilityIdentifier("settings_container")
        .frame(minWidth: 480, minHeight: 400)
    }
}

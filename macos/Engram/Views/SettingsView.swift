// macos/Engram/Views/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GeneralSettingsSection()
                AISettingsSection()
                SourcesSettingsSection()
                NetworkSettingsSection()
                AboutSettingsSection()
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}

// macos/Engram/Views/Settings/GeneralSettingsSection.swift
import SwiftUI

struct GeneralSettingsSection: View {
    @AppStorage("appLanguage") var appLanguage: String = AppLanguage.system.rawValue
    @AppStorage("contentFontSize") var contentFontSize: Double = 14
    @AppStorage("showDockIcon") var showDockIcon: Bool = false
    @AppStorage("showDeveloperTools") var showDeveloperTools: Bool = false
    @AppStorage("showMenuBarActivity") var showMenuBarActivity: Bool = true

    @Environment(EngramServiceStatusStore.self) var serviceStatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "gear", title: "General")

            // Display
            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Interface Language", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.label).tag(language.rawValue)
                        }
                    }
                    Text("Choose the language used by the macOS app UI. System follows your macOS language order.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack {
                        Text("Content Font Size")
                        Spacer()
                        Slider(value: $contentFontSize, in: 10...22, step: 1) { EmptyView() }
                            .frame(width: 160)
                        Text(verbatim: "\(Int(contentFontSize)) pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text("Preview: The quick brown fox jumps over the lazy dog")
                        .font(.system(size: contentFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
            }

            // Menu Bar
            GroupBox("Menu Bar") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show Activity in Menu Bar", isOn: $showMenuBarActivity)
                    Text("Show today's session count, live activity, and usage indicators next to the menu bar icon. Turn off to keep the icon static — a service failure still surfaces a warning.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            // Infrastructure
            GroupBox("Runtime Infrastructure") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Swift Service")
                        Spacer()
                        serviceStatusLabel
                            .foregroundStyle(.secondary)
                    }
                    Text("Primary runtime for the macOS app. Settings, search, indexing, and operational actions should use Swift service IPC during Stage 3.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            // Launch
            GroupBox("Launch") {
                VStack(alignment: .leading, spacing: 10) {
                    if #available(macOS 13.0, *) {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { LaunchAgent.isEnabled },
                            set: { LaunchAgent.setEnabled($0) }
                        ))
                    } else {
                        Text("Login item requires macOS 13+")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show Dock Icon", isOn: $showDockIcon)
                    Text("Keep the app icon visible in the Dock at all times")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Toggle("Show Developer Tools", isOn: $showDeveloperTools)
                    Text("Reveal the Observability section (internal logs, traces, and health diagnostics).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var serviceStatusLabel: some View {
        switch serviceStatusStore.status {
        case .stopped:
            Text("Stopped")
        case .starting:
            Text("Starting...")
        case .running(let total, _):
            Text("\(total) sessions indexed")
        case .degraded(let message):
            Text("Degraded: \(message)")
        case .error(let message):
            Text("Error: \(message)")
        }
    }

}

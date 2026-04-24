// macos/Engram/Views/Settings/GeneralSettingsSection.swift
import SwiftUI

struct GeneralSettingsSection: View {
    @AppStorage("contentFontSize") var contentFontSize: Double = 14
    @AppStorage("showSystemPrompts") var showSystemPrompts: Bool = false
    @AppStorage("showAgentComm") var showAgentComm: Bool = false
    @AppStorage("showDockIcon") var showDockIcon: Bool = false
    @AppStorage("httpPort") var httpPort: Int = 3456
    @AppStorage("nodejsPath") var nodejsPath: String = "/usr/local/bin/node"

    @Environment(EngramServiceStatusStore.self) var serviceStatusStore

    @State private var noiseFilter: String = "hide-skip"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "gear", title: "General")

            // Display
            GroupBox("Display") {
                VStack(alignment: .leading, spacing: 10) {
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

                    Toggle("Show System Prompts", isOn: $showSystemPrompts)
                    Text("CLAUDE.md, AGENTS.md, environment context, and other injected instructions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Toggle("Show Agent Communication", isOn: $showAgentComm)
                    Text("Tool calls, skill invocations, and command outputs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Session Filter
            GroupBox("Session Filter") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Session Filter", selection: $noiseFilter) {
                        Text("Show All").tag("all")
                        Text("Hide Agents & Noise").tag("hide-skip")
                        Text("Clean View").tag("hide-noise")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: noiseFilter) { saveNoiseSettings() }

                    Text(noiseFilterDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Infrastructure
            GroupBox("Runtime Infrastructure") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Swift Service")
                        Spacer()
                        Text(verbatim: serviceStatusStore.displayString)
                            .foregroundStyle(.secondary)
                    }
                    Text("Primary runtime for the macOS app. Settings, search, indexing, and operational actions should use Swift service IPC during Stage 3.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("Legacy Node rollback settings")
                        .font(.caption.bold())
                    Text("Kept for Stage 3 rollback and compatibility only. New setup should use the Swift service and bundled Swift stdio MCP helper.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Legacy HTTP Port")
                        Spacer()
                        TextField("3456", value: $httpPort, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Legacy MCP HTTP endpoint")
                        Spacer()
                        Text(verbatim: mcpEndpointText)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    HStack {
                        Text("Legacy Node.js Path")
                        Spacer()
                        TextField("/usr/local/bin/node", text: $nodejsPath)
                            .frame(width: 260)
                    }
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
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { loadNoiseSettings() }
    }

    private var noiseFilterDescription: String {
        switch noiseFilter {
        case "all": return "Show all sessions including agents and noise"
        case "hide-noise": return "Hide agents, empty sessions, and low-signal sessions"
        default: return "Hide sub-agents and trivial sessions (default)"
        }
    }

    private var mcpEndpointText: String {
        guard let port = serviceStatusStore.endpointPort else {
            return "Swift service MCP endpoint unavailable"
        }
        let host = serviceStatusStore.endpointHost ?? "127.0.0.1"
        return "http://\(host):\(port)/mcp"
    }

    private func saveNoiseSettings() {
        mutateEngramSettings { settings in
            settings["noiseFilter"] = noiseFilter
        }
    }

    private func loadNoiseSettings() {
        guard let settings = readEngramSettings() else { return }
        if let v = settings["noiseFilter"] as? String { noiseFilter = v }
    }
}

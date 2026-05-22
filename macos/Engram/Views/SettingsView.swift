// macos/Engram/Views/SettingsView.swift
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case ai
    case sources
    case network
    case advanced
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .ai: return "AI Summary"
        case .sources: return "Data Sources"
        case .network: return "Network"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .ai: return "brain"
        case .sources: return "folder"
        case .network: return "network"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selectedCategory: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    selectedSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
                .accessibilityElement(children: .contain)
            }
            .modernScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .accessibilityIdentifier("settings_container")
        .frame(minWidth: 760, minHeight: 540)
        .font(.system(size: 12))
        .controlSize(.small)
        .groupBoxStyle(SettingsCardGroupBoxStyle())
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 12)
            .padding(.top, 16)
            .accessibilityIdentifier("settings_title")

            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { category in
                    SettingsSidebarRow(
                        category: category,
                        isSelected: category == selectedCategory
                    ) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: 172)
        .background(Theme.surface.opacity(0.55))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings_nav")
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsSection()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings_section_general")
        case .ai:
            AISettingsSection()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings_section_ai")
        case .sources:
            SourcesSettingsSection()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings_section_sources")
        case .network:
            NetworkSettingsSection()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings_section_network")
        case .advanced:
            AdvancedSettingsSection()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings_section_advanced")
        case .about:
            AboutSettingsSection()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings_section_about")
        }
    }
}

private struct SettingsSidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(category.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .accessibilityIdentifier("settings_nav_\(category.rawValue)")
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Theme.sidebarSelectedText : Theme.secondaryText)
            .background(isSelected ? Theme.sidebarSelection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings_nav_\(category.rawValue)")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings_nav_\(category.rawValue)")
    }
}

private struct SettingsCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            configuration.content
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct AdvancedSettingsSection: View {
    @State private var httpHost = "127.0.0.1"
    @State private var httpAllowCIDR = ""
    @State private var httpBearerToken = ""
    // Embedding settings state removed — see Embeddings note in body.
    @State private var hideUsageSessions = true
    @State private var hideEmptySessions = true
    @State private var hideAutoSummary = true
    @State private var monitorEnabled = true
    @State private var dailyCostBudget = 20.0
    @State private var monthlyCostBudget = 0.0
    @State private var longSessionMinutes = 180
    @State private var notifyOnCostThreshold = true
    @State private var notifyOnLongSession = true
    @State private var logLevel = "info"
    @State private var logRetentionDays = 7
    @State private var aiAuditEnabled = true
    @State private var aiAuditRetentionDays = 30
    @State private var aiAuditMaxBodySize = 10000
    @State private var aiAuditLogBodies = false
    @State private var devMode = false
    @State private var isLoadingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "slider.horizontal.3", title: "Advanced")

            GroupBox("Web API & Security") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("HTTP Host")
                        Spacer()
                        TextField("127.0.0.1", text: $httpHost)
                            .frame(width: 220)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: httpHost) { saveAdvancedSettings() }
                    }
                    Text("Keep 127.0.0.1 unless you intentionally expose the legacy HTTP API on your LAN.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    HStack {
                        Text("Allowed CIDRs")
                        Spacer()
                        TextField("10.0.0.0/8, 192.168.0.0/16", text: $httpAllowCIDR)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: httpAllowCIDR) { saveAdvancedSettings() }
                    }
                    HStack {
                        Text("Bearer Token")
                        Spacer()
                        SecureField("Optional", text: $httpBearerToken)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: httpBearerToken) { saveAdvancedSettings() }
                    }
                    Text("Write APIs should use a bearer token when HTTP is reachable beyond localhost.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Embeddings controls removed — duplicate of the (now-removed)
            // AISettingsSection block. No Swift runtime reads these settings
            // (semantic search/embeddings are unimplemented), so the controls
            // were a false UI promise. See AISettingsSection for the rationale.

            GroupBox("Noise Details") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Hide usage-check sessions", isOn: $hideUsageSessions)
                        .onChange(of: hideUsageSessions) { saveAdvancedSettings() }
                    Toggle("Hide empty sessions", isOn: $hideEmptySessions)
                        .onChange(of: hideEmptySessions) { saveAdvancedSettings() }
                    Toggle("Hide auto-summary prompts", isOn: $hideAutoSummary)
                        .onChange(of: hideAutoSummary) { saveAdvancedSettings() }
                    Text("These are low-level filters behind the simplified Session Filter control.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Monitor & Budgets") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable background monitor", isOn: $monitorEnabled)
                        .onChange(of: monitorEnabled) { saveAdvancedSettings() }
                    HStack {
                        Text("Daily Budget")
                        Spacer()
                        TextField("20", value: $dailyCostBudget, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: dailyCostBudget) { saveAdvancedSettings() }
                        Text("USD")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Monthly Budget")
                        Spacer()
                        TextField("0", value: $monthlyCostBudget, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: monthlyCostBudget) { saveAdvancedSettings() }
                        Text("USD")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Long Session")
                        Spacer()
                        TextField("180", value: $longSessionMinutes, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: longSessionMinutes) { saveAdvancedSettings() }
                        Text("minutes")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Notify on cost threshold", isOn: $notifyOnCostThreshold)
                        .onChange(of: notifyOnCostThreshold) { saveAdvancedSettings() }
                    Toggle("Notify on long session", isOn: $notifyOnLongSession)
                        .onChange(of: notifyOnLongSession) { saveAdvancedSettings() }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Observability & AI Audit") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Log Level", selection: $logLevel) {
                        Text("Debug").tag("debug")
                        Text("Info").tag("info")
                        Text("Warn").tag("warn")
                        Text("Error").tag("error")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: logLevel) { saveAdvancedSettings() }

                    HStack {
                        Text("Log Retention")
                        Spacer()
                        TextField("7", value: $logRetentionDays, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: logRetentionDays) { saveAdvancedSettings() }
                        Text("days")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Enable AI audit", isOn: $aiAuditEnabled)
                        .onChange(of: aiAuditEnabled) { saveAdvancedSettings() }
                    Toggle("Log AI request/response bodies", isOn: $aiAuditLogBodies)
                        .onChange(of: aiAuditLogBodies) { saveAdvancedSettings() }
                    HStack {
                        Text("Audit Retention")
                        Spacer()
                        TextField("30", value: $aiAuditRetentionDays, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiAuditRetentionDays) { saveAdvancedSettings() }
                        Text("days")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Max Body Size")
                        Spacer()
                        TextField("10000", value: $aiAuditMaxBodySize, format: .number)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiAuditMaxBodySize) { saveAdvancedSettings() }
                        Text("bytes")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Developer Mode", isOn: $devMode)
                        .onChange(of: devMode) { saveAdvancedSettings() }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { loadAdvancedSettings() }
    }

    private func loadAdvancedSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        guard let settings = readEngramSettings() else { return }

        if let v = settings["httpHost"] as? String { httpHost = v }
        if let v = settings["httpAllowCIDR"] as? [String] { httpAllowCIDR = v.joined(separator: ", ") }
        if let v = settings["httpBearerToken"] as? String { httpBearerToken = v }
        if let v = settings["hideUsageSessions"] as? Bool { hideUsageSessions = v }
        if let v = settings["hideEmptySessions"] as? Bool { hideEmptySessions = v }
        if let v = settings["hideAutoSummary"] as? Bool { hideAutoSummary = v }
        if let costAlerts = settings["costAlerts"] as? [String: Any] {
            if let v = costAlerts["dailyBudget"] as? Double { dailyCostBudget = v }
            if let v = costAlerts["monthlyBudget"] as? Double { monthlyCostBudget = v }
        }
        if let monitor = settings["monitor"] as? [String: Any] {
            if let v = monitor["enabled"] as? Bool { monitorEnabled = v }
            if let v = monitor["dailyCostBudget"] as? Double { dailyCostBudget = v }
            if let v = monitor["monthlyCostBudget"] as? Double { monthlyCostBudget = v }
            if let v = monitor["longSessionMinutes"] as? Int { longSessionMinutes = v }
            if let v = monitor["notifyOnCostThreshold"] as? Bool { notifyOnCostThreshold = v }
            if let v = monitor["notifyOnLongSession"] as? Bool { notifyOnLongSession = v }
        }
        if let observability = settings["observability"] as? [String: Any] {
            if let v = observability["logLevel"] as? String { logLevel = v }
            if let v = observability["logRetentionDays"] as? Int { logRetentionDays = v }
        }
        if let audit = settings["aiAudit"] as? [String: Any] {
            if let v = audit["enabled"] as? Bool { aiAuditEnabled = v }
            if let v = audit["retentionDays"] as? Int { aiAuditRetentionDays = v }
            if let v = audit["maxBodySize"] as? Int { aiAuditMaxBodySize = v }
            if let v = audit["logBodies"] as? Bool { aiAuditLogBodies = v }
        }
        if let v = settings["devMode"] as? Bool { devMode = v }
    }

    private func saveAdvancedSettings() {
        guard !isLoadingSettings else { return }
        mutateEngramSettings { settings in
            if httpHost == "127.0.0.1" {
                settings.removeValue(forKey: "httpHost")
            } else {
                settings["httpHost"] = httpHost
            }
            let cidrs = httpAllowCIDR
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if cidrs.isEmpty {
                settings.removeValue(forKey: "httpAllowCIDR")
            } else {
                settings["httpAllowCIDR"] = cidrs
            }
            if httpBearerToken.isEmpty {
                settings.removeValue(forKey: "httpBearerToken")
            } else {
                settings["httpBearerToken"] = httpBearerToken
            }

            settings["hideUsageSessions"] = hideUsageSessions
            settings["hideEmptySessions"] = hideEmptySessions
            settings["hideAutoSummary"] = hideAutoSummary
            var costAlerts: [String: Any] = ["dailyBudget": dailyCostBudget]
            if monthlyCostBudget > 0 { costAlerts["monthlyBudget"] = monthlyCostBudget }
            settings["costAlerts"] = costAlerts
            var monitor: [String: Any] = [
                "enabled": monitorEnabled,
                "dailyCostBudget": dailyCostBudget,
                "longSessionMinutes": longSessionMinutes,
                "notifyOnCostThreshold": notifyOnCostThreshold,
                "notifyOnLongSession": notifyOnLongSession,
            ]
            if monthlyCostBudget > 0 { monitor["monthlyCostBudget"] = monthlyCostBudget }
            settings["monitor"] = monitor
            settings["observability"] = [
                "logLevel": logLevel,
                "logRetentionDays": logRetentionDays,
            ]
            settings["aiAudit"] = [
                "enabled": aiAuditEnabled,
                "retentionDays": aiAuditRetentionDays,
                "maxBodySize": aiAuditMaxBodySize,
                "logBodies": aiAuditLogBodies,
            ]
            settings["devMode"] = devMode
        }
    }
}

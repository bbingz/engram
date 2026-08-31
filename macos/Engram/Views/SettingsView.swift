// macos/Engram/Views/SettingsView.swift
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case ai
    case sources
    case archive
    case advanced
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .ai: return "AI Summary"
        case .sources: return "Data Sources"
        case .archive: return "Archive & Storage"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .ai: return "brain"
        case .sources: return "folder"
        case .archive: return "archivebox"
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
        .scaledFont(12)
        .controlSize(.small)
        .groupBoxStyle(SettingsCardGroupBoxStyle())
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .scaledFont(16, weight: .semibold)
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
        case .archive:
            VStack(alignment: .leading, spacing: 18) {
                LiveIngestSettingsSection()
                ArchiveSettingsSection()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings_section_archive")
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

func persistLiveIngestEnabled(
    requestedValue: Bool,
    currentPersistedValue: Bool,
    serviceIsRunning: Bool,
    mutateSettings: (((inout [String: Any]) -> Void) -> Bool)
) -> (enabled: Bool, restartNeeded: Bool, message: String?) {
    let persisted = mutateSettings { settings in
        settings["liveIngestEnabled"] = requestedValue
        if requestedValue {
            settings["liveIngestSources"] = ["hq"]
            settings["liveIngestPeerId"] = "hq"
        }
    }
    guard persisted else {
        return (
            currentPersistedValue,
            false,
            "Could not save HQ live ingest setting. The previous setting remains active."
        )
    }
    return (requestedValue, serviceIsRunning, nil)
}

private struct LiveIngestSettingsSection: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(\.engramServiceClient) private var serviceClient
    @Environment(EngramServiceStatusStore.self) private var serviceStatusStore

    @State private var enabled = false
    @State private var status: LiveIngestStatus?
    @State private var message: String?
    @State private var busy = false
    // live-ingest-arm-1 residual: toggling while the service is running does
    // not arm/disarm the coordinator until the service restarts.
    @State private var restartNeeded = false
    @State private var showResetConfirm = false

    private var serviceIsRunning: Bool {
        switch serviceStatusStore.status {
        case .running, .degraded: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "arrow.triangle.2.circlepath", title: "HQ Live Ingest")

            GroupBox("Pull HQ sessions into this Mac") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Enable HQ live ingest",
                        isOn: Binding(
                            get: { enabled },
                            set: { newValue in
                                persistEnabled(newValue)
                            }
                        )
                    )
                    .accessibilityIdentifier("liveIngest_enabled")

                    if restartNeeded && serviceIsRunning {
                        Text("Restart the Engram service for this change to take effect.")
                            .font(.caption)
                            .foregroundStyle(Theme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("liveIngest_restartHint")
                    }

                    Text("Imports HQ index snapshots into local search. Bundles are FTS and summary only — not raw transcripts. Resume stays on HQ.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let status {
                        LabeledContent("Last pull", value: status.lastPullAt ?? "—")
                        LabeledContent("Last generation", value: status.lastGeneration ?? "—")
                        LabeledContent("Imported HQ sessions", value: "\(status.importedCount)")
                        // Cumulative counter: every pull that finds an HQ session
                        // already present locally re-counts it, so this grows far
                        // faster than the number of distinct imported sessions.
                        LabeledContent("Occupancy skipped (cumulative)", value: "\(status.occupancySkipped)")
                        if status.occupancySkipped > 0 {
                            Text("Counts re-checks across pulls, not distinct sessions — duplicates are expected to inflate this total.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        LabeledContent("Last error", value: status.lastError?.isEmpty == false ? status.lastError! : "—")
                        LabeledContent("Shrink guard") {
                            Text(status.shrinkGuardLatched ? "Latched" : "OK")
                                .foregroundStyle(status.shrinkGuardLatched ? .orange : .secondary)
                        }
                        .accessibilityIdentifier("liveIngest_shrinkGuardStatus")
                        if status.shrinkGuardLatched {
                            Text("Shrink guard is latched. Imports still apply; retract is paused until a later in-cap complete generation or you reset the guard.")
                                .font(.caption)
                                .foregroundStyle(Theme.orange)
                        }
                    }

                    Button("Reset shrink guard") {
                        showResetConfirm = true
                    }
                    .disabled(busy || status?.shrinkGuardLatched != true)
                    .help(status?.shrinkGuardLatched == true
                        ? "Unlatch the shrink guard so retract can run again"
                        : "Shrink guard is not latched")
                    .accessibilityIdentifier("liveIngest_resetShrinkGuard")
                    .confirmationDialog(
                        "Reset shrink guard?",
                        isPresented: $showResetConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Reset shrink guard", role: .destructive) {
                            Task { await resetShrinkGuard() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Retract of removed HQ sessions stays paused while the guard is latched. Reset only if the local HQ slice is known to be complete.")
                    }

                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            load()
        }
        .onChange(of: serviceStatusStore.status) { _, newStatus in
            // A service restart cleared the armed-state mismatch.
            switch newStatus {
            case .stopped, .starting: restartNeeded = false
            default: break
            }
        }
    }

    private func load() {
        let settings = readEngramSettings() ?? [:]
        enabled = settings["liveIngestEnabled"] as? Bool ?? false
        status = try? db.liveIngestStatus(peer: "hq")
    }

    private func persistEnabled(_ value: Bool) {
        let result = persistLiveIngestEnabled(
            requestedValue: value,
            currentPersistedValue: enabled,
            serviceIsRunning: serviceIsRunning,
            mutateSettings: mutateEngramSettings
        )
        enabled = result.enabled
        restartNeeded = result.restartNeeded
        message = result.message
        status = try? db.liveIngestStatus(peer: "hq")
    }

    private func resetShrinkGuard() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await serviceClient.liveIngestResetShrinkGuard(peer: "hq")
            message = "Shrink guard reset."
            status = try? db.liveIngestStatus(peer: "hq")
        } catch {
            message = "Shrink guard reset failed: \(error.localizedDescription)"
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
                    .scaledFont(12)
                    .frame(width: 18)
                Text(category.title)
                    .scaledFont(12, weight: isSelected ? .semibold : .regular)
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
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(Theme.primaryText)

            configuration.content
                .scaledFont(12)
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
    @Environment(\.engramServiceClient) private var serviceClient
    @Environment(EngramServiceStatusStore.self) private var serviceStatusStore

    @AppStorage("showSystemPrompts") var showSystemPrompts: Bool = false
    @AppStorage("showAgentComm") var showAgentComm: Bool = false

    // Embedding settings state removed — see Embeddings note in body.
    @State private var monitorEnabled = true
    @State private var dailyCostBudget = 20.0
    @State private var monthlyCostBudget = 0.0
    @State private var longSessionMinutes = 180
    @State private var notifyOnCostThreshold = true
    @State private var notifyOnUsagePressure = true
    @State private var notifyOnLongSession = true
    @State private var usageLimitRows = UsageTokenLimitEditableRow.defaultRows
    @State private var customUsageSourceID = ""
    @State private var removedUsageLimitSourceIDs: Set<String> = []
    @State private var logLevel = "info"
    @State private var logRetentionDays = 7
    @State private var aiAuditEnabled = true
    @State private var aiAuditRetentionDays = 30
    @State private var aiAuditMaxBodySize = 10000
    @State private var aiAuditLogBodies = false
    @State private var devMode = false
    @State private var isLoadingSettings = false
    @State private var refreshUsageTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "slider.horizontal.3", title: "Advanced")

            // Embeddings controls removed — duplicate of the (now-removed)
            // AISettingsSection block. No Swift runtime reads these settings
            // (semantic search/embeddings are unimplemented), so the controls
            // were a false UI promise. See AISettingsSection for the rationale.

            GroupBox("Transcript Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
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
                    Toggle("Notify on usage pressure", isOn: $notifyOnUsagePressure)
                        .onChange(of: notifyOnUsagePressure) { saveAdvancedSettings() }
                    Toggle("Notify on long session", isOn: $notifyOnLongSession)
                        .onChange(of: notifyOnLongSession) { saveAdvancedSettings() }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Usage Limits") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($usageLimitRows) { $row in
                        UsageTokenLimitRow(
                            source: row.name,
                            fiveHourTokens: $row.fiveHourTokens,
                            weeklyTokens: $row.weeklyTokens,
                            canRemove: !row.isDefaultSource,
                            onChange: { saveAdvancedSettings(refreshUsage: true) },
                            onRemove: { removeUsageLimitRow(id: row.id) }
                        )
                    }
                    HStack(spacing: 8) {
                        TextField("source id", text: $customUsageSourceID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit(addUsageLimitRow)
                        Button(action: addUsageLimitRow) {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(UsageTokenLimitEditableRow.normalizedSourceID(customUsageSourceID).isEmpty)
                        .help("Add source")
                    }
                    Text("Leave a limit at 0 to disable pressure alerts for that window.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        .task { await loadAdvancedSettings() }
    }

    private func loadAdvancedSettings() async {
        isLoadingSettings = true
        defer { clearLoadingSettingsAfterViewUpdate() }
        guard let data = await AdvancedSettingsIO.loadOffMain(),
              !Task.isCancelled,
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

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
            if let v = monitor["notifyOnUsagePressure"] as? Bool { notifyOnUsagePressure = v }
            if let v = monitor["notifyOnLongSession"] as? Bool { notifyOnLongSession = v }
        }
        if let usageLimitsObject = settings["usageTokenLimits"] as? [String: Any] {
            let limits = UsageTokenLimitSettings(settingsObject: usageLimitsObject)
            usageLimitRows = UsageTokenLimitEditableRow.rows(for: limits)
        }
        removedUsageLimitSourceIDs.removeAll()
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

    private func clearLoadingSettingsAfterViewUpdate() {
        Task { @MainActor in
            await Task.yield()
            isLoadingSettings = false
        }
    }

    private func saveAdvancedSettings(refreshUsage: Bool = false) {
        guard !isLoadingSettings else { return }
        let snapshot = AdvancedSettingsPersistSnapshot(
            monitorEnabled: monitorEnabled,
            dailyCostBudget: dailyCostBudget,
            monthlyCostBudget: monthlyCostBudget,
            longSessionMinutes: longSessionMinutes,
            notifyOnCostThreshold: notifyOnCostThreshold,
            notifyOnUsagePressure: notifyOnUsagePressure,
            notifyOnLongSession: notifyOnLongSession,
            usageLimitRows: usageLimitRows,
            removedUsageLimitSourceIDs: removedUsageLimitSourceIDs,
            logLevel: logLevel,
            logRetentionDays: logRetentionDays,
            aiAuditEnabled: aiAuditEnabled,
            aiAuditRetentionDays: aiAuditRetentionDays,
            aiAuditMaxBodySize: aiAuditMaxBodySize,
            aiAuditLogBodies: aiAuditLogBodies,
            devMode: devMode
        )
        AdvancedSettingsIO.persistOffMain(snapshot) {
            if refreshUsage {
                scheduleUsageRefresh()
            }
        }
    }

    private func addUsageLimitRow() {
        let normalizedID = UsageTokenLimitEditableRow.normalizedSourceID(customUsageSourceID)
        let updated = UsageTokenLimitEditableRow.appendingCustomSource(
            customUsageSourceID,
            to: usageLimitRows
        )
        guard updated != usageLimitRows else { return }
        usageLimitRows = updated
        removedUsageLimitSourceIDs.remove(normalizedID)
        customUsageSourceID = ""
    }

    private func removeUsageLimitRow(id: String) {
        let normalizedID = UsageTokenLimitEditableRow.normalizedSourceID(id)
        guard !UsageTokenLimitEditableRow.isDefaultSourceID(normalizedID) else { return }
        usageLimitRows.removeAll { $0.id == normalizedID }
        removedUsageLimitSourceIDs.insert(normalizedID)
        saveAdvancedSettings(refreshUsage: true)
    }

    private func scheduleUsageRefresh() {
        refreshUsageTask?.cancel()
        refreshUsageTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                let response = try await serviceClient.refreshUsage()
                serviceStatusStore.apply(response)
            } catch is CancellationError {
            } catch {
                // Best effort: the service's periodic indexing loop will refresh later.
            }
        }
    }
}

struct AdvancedSettingsPersistSnapshot: Sendable {
    let monitorEnabled: Bool
    let dailyCostBudget: Double
    let monthlyCostBudget: Double
    let longSessionMinutes: Int
    let notifyOnCostThreshold: Bool
    let notifyOnUsagePressure: Bool
    let notifyOnLongSession: Bool
    let usageLimitRows: [UsageTokenLimitEditableRow]
    let removedUsageLimitSourceIDs: Set<String>
    let logLevel: String
    let logRetentionDays: Int
    let aiAuditEnabled: Bool
    let aiAuditRetentionDays: Int
    let aiAuditMaxBodySize: Int
    let aiAuditLogBodies: Bool
    let devMode: Bool
}

struct AdvancedSettingsPersistenceHooks: Sendable {
    let beforeMailbox: @Sendable (AdvancedSettingsPersistSnapshot) async -> Void
    let persist: @Sendable (AdvancedSettingsPersistSnapshot) -> Void
}

enum AdvancedSettingsIO {
    private static let mailbox = Mailbox()
    @MainActor private static var persistenceTail: Task<Void, Never>?

    static func loadOffMain() async -> Data? {
        await Task.detached(priority: .userInitiated) {
            readEngramSettingsData()
        }.value
    }

    @MainActor
    static func persistOffMain(
        _ snapshot: AdvancedSettingsPersistSnapshot,
        testHooks: AdvancedSettingsPersistenceHooks? = nil,
        onPersisted: @escaping @MainActor @Sendable () -> Void
    ) {
        let previous = persistenceTail
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            if let testHooks {
                await testHooks.beforeMailbox(snapshot)
            }
            await mailbox.persist(snapshot, override: testHooks?.persist)
            await onPersisted()
        }
        persistenceTail = task
    }

    actor Mailbox {
        func persist(
            _ snapshot: AdvancedSettingsPersistSnapshot,
            override: (@Sendable (AdvancedSettingsPersistSnapshot) -> Void)? = nil
        ) {
            if let override {
                override(snapshot)
                return
            }
            mutateEngramSettings { settings in
                // No Swift runtime reads these legacy HTTP/Web UI/security keys.
                settings.removeValue(forKey: "httpHost")
                settings.removeValue(forKey: "httpAllowCIDR")
                settings.removeValue(forKey: "httpBearerToken")
                settings.removeValue(forKey: "webUIEnabled")

                var costAlerts: [String: Any] = ["dailyBudget": snapshot.dailyCostBudget]
                if snapshot.monthlyCostBudget > 0 {
                    costAlerts["monthlyBudget"] = snapshot.monthlyCostBudget
                }
                settings["costAlerts"] = costAlerts
                var monitor: [String: Any] = [
                    "enabled": snapshot.monitorEnabled,
                    "dailyCostBudget": snapshot.dailyCostBudget,
                    "longSessionMinutes": snapshot.longSessionMinutes,
                    "notifyOnCostThreshold": snapshot.notifyOnCostThreshold,
                    "notifyOnUsagePressure": snapshot.notifyOnUsagePressure,
                    "notifyOnLongSession": snapshot.notifyOnLongSession,
                ]
                if snapshot.monthlyCostBudget > 0 {
                    monitor["monthlyCostBudget"] = snapshot.monthlyCostBudget
                }
                settings["monitor"] = monitor
                let usageTokenLimits = UsageTokenLimitEditableRow.settingsObject(
                    from: snapshot.usageLimitRows,
                    preservingUnknownFrom: settings["usageTokenLimits"] as? [String: Any],
                    excludingSourceIDs: snapshot.removedUsageLimitSourceIDs
                )
                if usageTokenLimits.isEmpty {
                    settings.removeValue(forKey: "usageTokenLimits")
                } else {
                    settings["usageTokenLimits"] = usageTokenLimits
                }
                settings["observability"] = [
                    "logLevel": snapshot.logLevel,
                    "logRetentionDays": snapshot.logRetentionDays,
                ]
                settings["aiAudit"] = [
                    "enabled": snapshot.aiAuditEnabled,
                    "retentionDays": snapshot.aiAuditRetentionDays,
                    "maxBodySize": snapshot.aiAuditMaxBodySize,
                    "logBodies": snapshot.aiAuditLogBodies,
                ]
                settings["devMode"] = snapshot.devMode
            }
        }
    }
}

struct UsageTokenLimitEditableRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var fiveHourTokens: Double
    var weeklyTokens: Double

    static let defaultRows: [UsageTokenLimitEditableRow] = [
        UsageTokenLimitEditableRow(id: "codex", name: "Codex"),
        UsageTokenLimitEditableRow(id: "claude-code", name: "Claude Code"),
        UsageTokenLimitEditableRow(id: "opencode", name: "OpenCode"),
        UsageTokenLimitEditableRow(id: "copilot", name: "Copilot"),
        UsageTokenLimitEditableRow(id: "gemini-cli", name: "Gemini CLI"),
        UsageTokenLimitEditableRow(id: "iflow", name: "Iflow"),
        UsageTokenLimitEditableRow(id: "qwen", name: "Qwen"),
        UsageTokenLimitEditableRow(id: "qoder", name: "Qoder"),
        UsageTokenLimitEditableRow(id: "kimi", name: "Kimi"),
        UsageTokenLimitEditableRow(id: "cline", name: "Cline"),
    ]

    var isDefaultSource: Bool {
        Self.isDefaultSourceID(id)
    }

    init(id: String, name: String, fiveHourTokens: Double = 0, weeklyTokens: Double = 0) {
        self.id = id
        self.name = name
        self.fiveHourTokens = fiveHourTokens
        self.weeklyTokens = weeklyTokens
    }

    static func rows(for settings: UsageTokenLimitSettings) -> [UsageTokenLimitEditableRow] {
        let defaultIDs = Set(defaultRows.map(\.id))
        let configuredRows = defaultRows.map { row in
            row.with(limit: settings.limit(for: row.id))
        }
        let extraRows = settings.sourceIDs
            .filter { !defaultIDs.contains($0) }
            .map { sourceID in
                UsageTokenLimitEditableRow(
                    id: sourceID,
                    name: displayName(for: sourceID)
                ).with(limit: settings.limit(for: sourceID))
            }
        return configuredRows + extraRows
    }

    static func appendingCustomSource(
        _ rawSourceID: String,
        to rows: [UsageTokenLimitEditableRow]
    ) -> [UsageTokenLimitEditableRow] {
        let sourceID = normalizedSourceID(rawSourceID)
        guard !sourceID.isEmpty else { return rows }
        guard !rows.contains(where: { $0.id == sourceID }) else { return rows }
        return rows + [UsageTokenLimitEditableRow(id: sourceID, name: displayName(for: sourceID))]
    }

    static func settings(from rows: [UsageTokenLimitEditableRow]) -> UsageTokenLimitSettings {
        UsageTokenLimitSettings(
            sourceLimits: rows.reduce(into: [:]) { result, row in
                result[row.id] = UsageTokenLimitSettings.Limit(
                    fiveHourTokens: row.fiveHourTokens,
                    weeklyTokens: row.weeklyTokens
                )
            }
        )
    }

    static func settingsObject(
        from rows: [UsageTokenLimitEditableRow],
        preservingUnknownFrom existingObject: [String: Any]?,
        excludingSourceIDs: Set<String> = []
    ) -> [String: [String: Double]] {
        let representedIDs = Set(rows.map { normalizedSourceID($0.id) }.filter { !$0.isEmpty })
        let excludedIDs = Set(excludingSourceIDs.map { normalizedSourceID($0) }.filter { !$0.isEmpty })
        var object = UsageTokenLimitSettings(settingsObject: existingObject ?? [:]).settingsObject()
            .filter { !representedIDs.contains($0.key) && !excludedIDs.contains($0.key) }

        settings(from: rows).settingsObject().forEach { sourceID, source in
            object[sourceID] = source
        }
        return object
    }

    private func with(limit: UsageTokenLimitSettings.Limit?) -> UsageTokenLimitEditableRow {
        UsageTokenLimitEditableRow(
            id: id,
            name: name,
            fiveHourTokens: limit?.fiveHourTokens ?? 0,
            weeklyTokens: limit?.weeklyTokens ?? 0
        )
    }

    static func normalizedSourceID(_ sourceID: String) -> String {
        sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isDefaultSourceID(_ sourceID: String) -> Bool {
        let normalizedID = normalizedSourceID(sourceID)
        return defaultRows.contains { $0.id == normalizedID }
    }

    private static func displayName(for sourceID: String) -> String {
        switch sourceID {
        case "codex": return "Codex"
        case "claude-code": return "Claude Code"
        case "opencode": return "OpenCode"
        case "copilot": return "Copilot"
        case "gemini-cli": return "Gemini CLI"
        case "iflow": return "Iflow"
        case "qwen": return "Qwen"
        case "qoder": return "Qoder"
        case "kimi": return "Kimi"
        case "cline": return "Cline"
        default: return sourceID
        }
    }
}

private struct UsageTokenLimitRow: View {
    let source: String
    @Binding var fiveHourTokens: Double
    @Binding var weeklyTokens: Double
    let canRemove: Bool
    let onChange: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(source)
                .frame(width: 92, alignment: .leading)
            Spacer(minLength: 8)
            TextField("0", value: $fiveHourTokens, format: .number)
                .frame(width: 88)
                .multilineTextAlignment(.trailing)
                .onChange(of: fiveHourTokens) { onChange() }
            Text("5h")
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            TextField("0", value: $weeklyTokens, format: .number)
                .frame(width: 88)
                .multilineTextAlignment(.trailing)
                .onChange(of: weeklyTokens) { onChange() }
            Text("weekly")
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .opacity(canRemove ? 1 : 0)
            .help("Remove source")
        }
    }
}

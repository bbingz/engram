// macos/Engram/Views/Settings/NetworkSettingsSection.swift
import SwiftUI

struct NetworkSettingsSection: View {
    @Environment(EngramServiceClient.self) var serviceClient

    // Sync
    @State private var syncEnabled: Bool = false
    @State private var syncNodeName: String = ""
    @State private var syncPeers: [[String: String]] = []
    @State private var syncIntervalMinutes: Int = 30
    @State private var syncStatus: String = ""
    @State private var isSyncing: Bool = false

    // MCP service single-writer policy. The legacy Node daemon rollback path
    // still exists during Stage 3, but Swift service IPC is the primary writer.
    @State private var mcpStrictSingleWriter: Bool = false

    @State private var isLoadingSettings: Bool = false

    // Add peer form
    @State private var showAddPeer: Bool = false
    @State private var newPeerName: String = ""
    @State private var newPeerURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "network", title: "Network")

            // Sync
            GroupBox("Sync") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Sync", isOn: $syncEnabled)
                        .onChange(of: syncEnabled) { saveSyncSettings() }

                    HStack {
                        Text("Node Name")
                        Spacer()
                        TextField("e.g. macbook-pro", text: $syncNodeName)
                            .frame(width: 200)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: syncNodeName) { saveSyncSettings() }
                    }

                    HStack {
                        Text("Interval (minutes)")
                        Spacer()
                        TextField("30", value: $syncIntervalMinutes, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: syncIntervalMinutes) {
                                if syncIntervalMinutes < 1 { syncIntervalMinutes = 1 }
                                saveSyncSettings()
                            }
                    }

                    // Peer list
                    if !syncPeers.isEmpty {
                        ForEach(Array(syncPeers.enumerated()), id: \.offset) { index, peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: peer["name"] ?? "")
                                        .font(.caption.bold())
                                    Text(verbatim: peer["url"] ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    syncPeers.remove(at: index)
                                    saveSyncSettings()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                        }
                    }

                    // Add peer
                    if showAddPeer {
                        VStack(spacing: 6) {
                            HStack {
                                Text("Name")
                                    .font(.caption)
                                    .frame(width: 40, alignment: .leading)
                                TextField("e.g. imac-studio", text: $newPeerName)
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("URL")
                                    .font(.caption)
                                    .frame(width: 40, alignment: .leading)
                                TextField("http://198.51.100.10:3457", text: $newPeerURL)
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Button("Cancel") {
                                    showAddPeer = false
                                    newPeerName = ""
                                    newPeerURL = ""
                                }
                                .font(.caption)
                                Spacer()
                                Button("Add") {
                                    if !newPeerName.isEmpty && !newPeerURL.isEmpty {
                                        syncPeers.append(["name": newPeerName, "url": newPeerURL])
                                        saveSyncSettings()
                                        newPeerName = ""
                                        newPeerURL = ""
                                        showAddPeer = false
                                    }
                                }
                                .font(.caption)
                                .disabled(newPeerName.isEmpty || newPeerURL.isEmpty)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Button("Add Peer") {
                            showAddPeer = true
                        }
                        .font(.caption)
                    }

                    // Sync Now
                    HStack {
                        Button {
                            triggerSync()
                        } label: {
                            Text("Sync Now")
                        }
                        .disabled(isSyncing || !syncEnabled)

                        if !syncStatus.isEmpty {
                            Text(verbatim: syncStatus)
                                .font(.caption)
                                .foregroundStyle(syncStatus == "Failed" ? .red : .secondary)
                        }
                    }

                    Text("Sync settings are stored in ~/.engram/settings.json")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
            loadSyncSettings()
        }
    }

    // MARK: - Sync

    private func saveSyncSettings() {
        guard !isLoadingSettings else { return }
        mutateEngramSettings { settings in
            settings["syncEnabled"] = syncEnabled
            settings["syncNodeName"] = syncNodeName
            settings["syncIntervalMinutes"] = syncIntervalMinutes
            settings["syncPeers"] = syncPeers
        }
    }

    private func loadSyncSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        guard let settings = readEngramSettings() else { return }
        if let enabled = settings["syncEnabled"] as? Bool { syncEnabled = enabled }
        if let name = settings["syncNodeName"] as? String { syncNodeName = name }
        if let interval = settings["syncIntervalMinutes"] as? Int { syncIntervalMinutes = interval }
        if let peers = settings["syncPeers"] as? [[String: String]] { syncPeers = peers }
        if let strict = settings["mcpStrictSingleWriter"] as? Bool { mcpStrictSingleWriter = strict }
    }

    private func saveMcpSettings() {
        guard !isLoadingSettings else { return }
        mutateEngramSettings { settings in
            settings["mcpStrictSingleWriter"] = mcpStrictSingleWriter
        }
    }

    private func triggerSync() {
        isSyncing = true
        syncStatus = "Syncing..."
        Task {
            do {
                let response = try await serviceClient.triggerSync(
                    EngramServiceTriggerSyncRequest(peer: nil)
                )
                isSyncing = false
                let failed = response.results.contains { item in
                    if let ok = item.ok {
                        return !ok
                    }
                    return item.error != nil
                }
                if failed {
                    syncStatus = "Failed"
                    return
                }
                syncStatus = "Synced!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if syncStatus == "Synced!" { syncStatus = "" }
                }
            } catch {
                isSyncing = false
                syncStatus = "Failed"
                EngramLogger.error("Network sync failed", module: .network, error: error)
            }
        }
    }
}

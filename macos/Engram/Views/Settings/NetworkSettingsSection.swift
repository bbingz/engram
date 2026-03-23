// macos/Engram/Views/Settings/NetworkSettingsSection.swift
import SwiftUI

struct NetworkSettingsSection: View {
    // Sync
    @State private var syncEnabled: Bool = false
    @State private var syncNodeName: String = ""
    @State private var syncPeers: [[String: String]] = []
    @State private var syncIntervalMinutes: Int = 30
    @State private var syncStatus: String = ""
    @State private var isSyncing: Bool = false

    // Viking
    @State private var vikingEnabled: Bool = false
    @State private var vikingURL: String = ""
    @State private var vikingApiKey: String = ""
    @State private var vikingStatus: String = ""
    @State private var isCheckingViking: Bool = false
    @State private var isLoadingSettings: Bool = false

    // Add peer form
    @State private var showAddPeer: Bool = false
    @State private var newPeerName: String = ""
    @State private var newPeerURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "network", title: "Network")

            // OpenViking
            GroupBox("OpenViking") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable", isOn: $vikingEnabled)
                        .onChange(of: vikingEnabled) { saveVikingSettings() }

                    HStack {
                        Text("Server URL")
                        Spacer()
                        TextField("http://localhost:1933", text: $vikingURL)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: vikingURL) { saveVikingSettings() }
                    }

                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("Required", text: $vikingApiKey)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: vikingApiKey) { saveVikingSettings() }
                    }

                    HStack {
                        Button {
                            checkVikingStatus()
                        } label: {
                            Text("Test Connection")
                        }
                        .disabled(isCheckingViking || !vikingEnabled || vikingURL.isEmpty)

                        if !vikingStatus.isEmpty {
                            Circle()
                                .fill(vikingStatus == "Connected" ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(verbatim: vikingStatus)
                                .font(.caption)
                                .foregroundStyle(vikingStatus == "Connected" ? .green : .red)
                        }
                    }

                    Text("OpenViking enhances search with semantic understanding and tiered summaries")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

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
                                TextField("http://192.168.1.100:3457", text: $newPeerURL)
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
        }
        .onAppear {
            loadSyncSettings()
            loadVikingSettings()
        }
    }

    // MARK: - Viking

    private func saveVikingSettings() {
        guard !isLoadingSettings else { return }
        // Save Viking API key to Keychain
        if !vikingApiKey.isEmpty {
            let saved = KeychainHelper.set("vikingApiKey", value: vikingApiKey)
            if saved {
                mutateEngramSettings { settings in
                    var viking = settings["viking"] as? [String: Any] ?? [:]
                    viking["apiKey"] = "@keychain"
                    viking["enabled"] = vikingEnabled
                    if !vikingURL.isEmpty { viking["url"] = vikingURL }
                    settings["viking"] = viking
                }
                return
            }
        } else {
            KeychainHelper.delete("vikingApiKey")
        }
        mutateEngramSettings { settings in
            var viking: [String: Any] = [:]
            viking["enabled"] = vikingEnabled
            if !vikingURL.isEmpty { viking["url"] = vikingURL }
            // Keychain unavailable — fall back to plaintext JSON
            if !vikingApiKey.isEmpty { viking["apiKey"] = vikingApiKey }
            settings["viking"] = viking
        }
    }

    private func loadVikingSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        guard let settings = readEngramSettings(),
              let viking = settings["viking"] as? [String: Any] else { return }
        if let enabled = viking["enabled"] as? Bool { vikingEnabled = enabled }
        if let url = viking["url"] as? String { vikingURL = url }
        vikingApiKey = KeychainHelper.get("vikingApiKey")
            ?? { let v = viking["apiKey"] as? String; return v == "@keychain" ? nil : v }() ?? ""
    }

    private func checkVikingStatus() {
        isCheckingViking = true
        vikingStatus = ""

        guard let url = URL(string: "\(vikingURL)/api/v1/debug/health") else {
            vikingStatus = "Invalid URL"
            isCheckingViking = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(vikingApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isCheckingViking = false
                if let error = error {
                    vikingStatus = "Error: \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) {
                    vikingStatus = "Connected"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if vikingStatus == "Connected" { vikingStatus = "" }
                    }
                } else {
                    vikingStatus = "Unreachable"
                }
            }
        }.resume()
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
    }

    private func triggerSync() {
        isSyncing = true
        syncStatus = "Syncing..."

        let webPort: Int = (readEngramSettings()?["httpPort"] as? Int) ?? 3457

        guard let url = URL(string: "http://localhost:\(webPort)/api/sync/trigger") else {
            syncStatus = "Failed"
            isSyncing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = readEngramSettings()?["httpBearerToken"] as? String {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isSyncing = false
                if let error = error {
                    syncStatus = "Failed"
                    print("Sync error: \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) {
                    syncStatus = "Synced!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if syncStatus == "Synced!" { syncStatus = "" }
                    }
                } else {
                    syncStatus = "Failed"
                }
            }
        }.resume()
    }
}

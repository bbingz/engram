import SwiftUI

struct ArchiveSettingsSection: View {
    @Environment(EngramServiceClient.self) private var serviceClient

    @State private var status: EngramServiceArchiveReclamationStatusResponse?
    @State private var preview: EngramServiceArchiveReclamationPreviewResponse?
    @State private var enabled = false
    @State private var hotWindowDays = 30
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "archivebox", title: "Archive & Storage")

            GroupBox("Automatic Local Reclamation") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Automatically reclaim old local transcripts", isOn: $enabled)
                        .disabled(busy)
                        .accessibilityIdentifier("archiveReclamation_enabled")

                    Picker("Keep full local transcripts", selection: $hotWindowDays) {
                        ForEach([30, 60, 90, 180], id: \.self) { days in
                            Text("\(days) days").tag(days)
                        }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("archiveReclamation_hotWindow")

                    Text("Search metadata and summaries remain local. Older source files and local archive objects are reclaimed only after both remote copies and both current recovery drills are verified.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Button("Save") { Task { await save() } }
                            .disabled(busy)
                            .accessibilityIdentifier("archiveReclamation_save")
                        Button("Preview") { Task { await loadPreview() } }
                            .disabled(busy)
                            .accessibilityIdentifier("archiveReclamation_preview")
                        Button("Run Now") { Task { await runNow() } }
                            .disabled(busy || status?.enabled != true)
                            .accessibilityIdentifier("archiveReclamation_run")
                    }

                    if let status {
                        Label(
                            status.recoveryLeaseCurrent ? "Recovery drills current" : "Recovery drills required",
                            systemImage: status.recoveryLeaseCurrent ? "checkmark.shield" : "exclamationmark.shield"
                        )
                        .foregroundStyle(status.recoveryLeaseCurrent ? .green : .orange)
                    }
                    if let preview {
                        Text("Preview: \(preview.eligibleCount) files, about \(ByteCountFormatter.string(fromByteCount: preview.estimatedSourceBytes, countStyle: .file)).")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Lightweight Recovery Drills") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Each drill restores and verifies one bounded archived transcript. It does not scan the entire archive.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    HStack {
                        Button("Verify HQ") { Task { await drill("hq") } }
                            .disabled(busy)
                        Button("Verify M1") { Task { await drill("m1") } }
                            .disabled(busy)
                    }
                }
                .padding(.vertical, 4)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("Error:") ? .red : .secondary)
                    .accessibilityIdentifier("archiveReclamation_message")
            }
        }
        .task { await refresh() }
    }

    @MainActor
    private func refresh() async {
        do {
            let value = try await serviceClient.archiveReclamationStatus()
            status = value
            enabled = value.enabled
            hotWindowDays = value.hotWindowDays
        } catch {
            message = "Error: archive status unavailable."
        }
    }

    @MainActor
    private func save() async {
        busy = true
        defer { busy = false }
        do {
            status = try await serviceClient.archiveReclamationUpdateSettings(
                .init(enabled: enabled, hotWindowDays: hotWindowDays)
            )
            message = enabled ? "Automatic reclamation enabled." : "Automatic reclamation disabled."
        } catch {
            await refresh()
            message = "Error: run both recovery drills before enabling automatic reclamation."
        }
    }

    @MainActor
    private func loadPreview() async {
        busy = true
        defer { busy = false }
        do {
            preview = try await serviceClient.archiveReclamationPreview()
            message = nil
        } catch {
            message = "Error: preview unavailable."
        }
    }

    @MainActor
    private func runNow() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await serviceClient.archiveReclamationRun()
            message = result.accepted
                ? "Released \(ByteCountFormatter.string(fromByteCount: result.releasedBytes, countStyle: .file))."
                : "Error: reclamation is paused."
            await refresh()
        } catch {
            message = "Error: reclamation run failed."
        }
    }

    @MainActor
    private func drill(_ replicaID: String) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await serviceClient.archiveV2RecoveryDrill(.init(replicaID: replicaID))
            message = "\(replicaID.uppercased()) recovery drill passed."
            await refresh()
        } catch {
            message = "Error: \(replicaID.uppercased()) recovery drill failed."
        }
    }
}

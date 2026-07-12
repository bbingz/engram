import SwiftUI

enum ArchiveSyncPresentationState: Equatable {
    case unavailable
    case disabled
    case needsAttention
    case inProgress
    case complete

    init(status: EngramServiceArchiveV2StatusResponse?) {
        guard let status else {
            self = .unavailable
            return
        }

        let hasAttentionState = status.configurationError != nil
            || status.lastCaptureError != nil
            || status.lastReplicationError != nil
            || status.unsafeLocatorCount > 0
            || status.replicas.contains { $0.quarantinedCount > 0 }
        if hasAttentionState {
            self = .needsAttention
            return
        }

        guard status.enabled, status.remoteReplicationEnabled else {
            self = .disabled
            return
        }

        let hasPendingWork = status.cycleRunning
            || status.dualReplicaVerifiedCount < status.remotePolicyEligibleCount
            || status.replicas.contains { $0.queuedCount > 0 || $0.retryingCount > 0 }
        self = hasPendingWork ? .inProgress : .complete
    }
}

struct ArchiveSettingsSection: View {
    @Environment(EngramServiceClient.self) private var serviceClient

    @State private var archiveStatus: EngramServiceArchiveV2StatusResponse?
    @State private var status: EngramServiceArchiveReclamationStatusResponse?
    @State private var preview: EngramServiceArchiveReclamationPreviewResponse?
    @State private var enabled = false
    @State private var hotWindowDays = 30
    @State private var busy = false
    @State private var syncBusy = false
    @State private var syncRefreshGeneration = 0
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "archivebox", title: "Archive & Storage")

            archiveSyncStatusCard

            GroupBox("Automatic Local Reclamation") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Automatically reclaim old local transcripts", isOn: $enabled)
                        .disabled(busy)
                        .accessibilityIdentifier("archiveReclamation_enabled")

                    Picker("Keep full local transcripts", selection: $hotWindowDays) {
                        ForEach([30, 60, 90, 180], id: \.self) { days in
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "%lld days"),
                                    Int64(days)
                                )
                            )
                            .tag(days)
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
                            status.recoveryLeaseCurrent
                                ? String(localized: "Recovery drills current")
                                : String(localized: "Recovery drills required"),
                            systemImage: status.recoveryLeaseCurrent ? "checkmark.shield" : "exclamationmark.shield"
                        )
                        .foregroundStyle(status.recoveryLeaseCurrent ? .green : .orange)
                    }
                    if let preview {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Preview: %lld files, about %@."),
                                Int64(preview.eligibleCount),
                                ByteCountFormatter.string(
                                    fromByteCount: preview.estimatedSourceBytes,
                                    countStyle: .file
                                )
                            )
                        )
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
                    .foregroundStyle(messageIsError ? .red : .secondary)
                    .accessibilityIdentifier("archiveReclamation_message")
            }
        }
        .task { await refresh() }
    }

    private var archiveSyncStatusCard: some View {
        GroupBox("Archive Sync Status") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(syncPresentation.text, systemImage: syncPresentation.icon)
                        .foregroundStyle(syncPresentation.color)
                        .accessibilityIdentifier("archiveSync_status")
                    Spacer()
                    Button("Refresh Status") { Task { await refreshArchiveStatus() } }
                        .disabled(syncBusy)
                        .accessibilityIdentifier("archiveSync_refresh")
                }

                if let archiveStatus {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Dual-copy verified: %lld of %lld"),
                            Int64(archiveStatus.dualReplicaVerifiedCount),
                            Int64(archiveStatus.remotePolicyEligibleCount)
                        )
                    )
                    .font(.caption)
                    .accessibilityIdentifier("archiveSync_progress")

                    ForEach(archiveStatus.replicas, id: \.replicaID) { replica in
                        Text(replicaSummary(replica))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                replica.replicaID == "hq" ? "archiveSync_hq" : "archiveSync_m1"
                            )
                    }

                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%lld unbound archives (not a sync failure)"),
                            Int64(archiveStatus.unboundCount)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("archiveSync_unbound")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var syncPresentation: (text: String, icon: String, color: Color) {
        switch ArchiveSyncPresentationState(status: archiveStatus) {
        case .unavailable:
            return (String(localized: "Sync status unavailable"), "questionmark.circle", .secondary)
        case .disabled:
            return (String(localized: "Archive synchronization disabled"), "pause.circle", .secondary)
        case .needsAttention:
            return (String(localized: "Archive synchronization needs attention"), "exclamationmark.triangle", .orange)
        case .inProgress:
            return (String(localized: "Archive synchronization in progress"), "arrow.triangle.2.circlepath", .blue)
        case .complete:
            return (String(localized: "Archive synchronization complete"), "checkmark.circle", .green)
        }
    }

    private func replicaSummary(_ replica: EngramServiceArchiveV2ReplicaStatus) -> String {
        String.localizedStringWithFormat(
            String(localized: "%@: %lld verified, %lld retrying, %lld queued, %lld quarantined"),
            replica.replicaID.uppercased(),
            Int64(replica.verifiedCount),
            Int64(replica.retryingCount),
            Int64(replica.queuedCount),
            Int64(replica.quarantinedCount)
        )
    }

    @MainActor
    private func refreshArchiveStatus() async {
        syncRefreshGeneration += 1
        let requestGeneration = syncRefreshGeneration
        syncBusy = true
        defer {
            if requestGeneration == syncRefreshGeneration {
                syncBusy = false
            }
        }
        do {
            let value = try await serviceClient.archiveV2Status()
            guard requestGeneration == syncRefreshGeneration else { return }
            archiveStatus = value
        } catch {
            guard requestGeneration == syncRefreshGeneration else { return }
            archiveStatus = nil
        }
    }

    @MainActor
    private func refresh(reportError: Bool = true) async {
        await refreshArchiveStatus()
        do {
            let value = try await serviceClient.archiveReclamationStatus()
            status = value
            enabled = value.enabled
            hotWindowDays = value.hotWindowDays
        } catch {
            if reportError {
                message = String(localized: "Error: archive status unavailable.")
                messageIsError = true
            }
        }
    }

    @MainActor
    private func save() async {
        busy = true
        defer { busy = false }
        let requestedEnabled = enabled
        do {
            status = try await serviceClient.archiveReclamationUpdateSettings(
                .init(enabled: enabled, hotWindowDays: hotWindowDays)
            )
            message = enabled
                ? String(localized: "Automatic reclamation enabled.")
                : String(localized: "Automatic reclamation disabled.")
            messageIsError = false
        } catch {
            await refresh(reportError: false)
            message = requestedEnabled
                ? String(localized: "Error: save failed. Verify both recovery drills are current and the service is available.")
                : String(localized: "Error: save failed because the service is unavailable.")
            messageIsError = true
        }
    }

    @MainActor
    private func loadPreview() async {
        busy = true
        defer { busy = false }
        do {
            preview = try await serviceClient.archiveReclamationPreview()
            message = nil
            messageIsError = false
        } catch {
            message = String(localized: "Error: preview unavailable.")
            messageIsError = true
        }
    }

    @MainActor
    private func runNow() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await serviceClient.archiveReclamationRun()
            if result.accepted {
                message = String.localizedStringWithFormat(
                    String(localized: "Released %@."),
                    ByteCountFormatter.string(fromByteCount: result.releasedBytes, countStyle: .file)
                )
                messageIsError = false
            } else {
                switch result.error {
                case "reclamation_paused":
                    message = String(localized: "Error: reclamation is paused until its safety gates are current.")
                case "cancelled":
                    message = String(localized: "Error: reclamation was cancelled.")
                case "archive_v2_disabled":
                    message = String(localized: "Error: exact archive storage is disabled.")
                default:
                    message = String(localized: "Error: reclamation failed.")
                }
                messageIsError = true
            }
            await refresh(reportError: false)
        } catch {
            message = String(localized: "Error: reclamation run failed.")
            messageIsError = true
        }
    }

    @MainActor
    private func drill(_ replicaID: String) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await serviceClient.archiveV2RecoveryDrill(.init(replicaID: replicaID))
            message = String.localizedStringWithFormat(
                String(localized: "%@ recovery drill passed."),
                replicaID.uppercased()
            )
            messageIsError = false
            await refresh(reportError: false)
        } catch {
            message = String.localizedStringWithFormat(
                String(localized: "Error: %@ recovery drill failed."),
                replicaID.uppercased()
            )
            messageIsError = true
        }
    }
}

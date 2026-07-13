import SwiftUI

enum ArchiveSyncRetryCategory: CaseIterable, Hashable {
    case network
    case credentials
    case localArchive
    case remoteVerification
    case configuration
    case other

    var localizedName: String {
        switch self {
        case .network: String(localized: "Network")
        case .credentials: String(localized: "Credentials")
        case .localArchive: String(localized: "Local archive")
        case .remoteVerification: String(localized: "Remote verification")
        case .configuration: String(localized: "Configuration")
        case .other: String(localized: "Other")
        }
    }
}

struct ArchiveSyncRetryCategoryCount: Equatable {
    let category: ArchiveSyncRetryCategory
    let count: Int
}

enum ArchiveSyncRetryPresentation {
    static func group(
        _ reasons: [EngramServiceArchiveV2RetryReasonCount]
    ) -> [ArchiveSyncRetryCategoryCount] {
        var counts: [ArchiveSyncRetryCategory: Int] = [:]
        for reason in reasons {
            let category = category(for: reason.symbol)
            let (sum, overflow) = counts[category, default: 0]
                .addingReportingOverflow(reason.count)
            counts[category] = overflow ? Int.max : sum
        }
        return ArchiveSyncRetryCategory.allCases.compactMap { category in
            guard let count = counts[category], count > 0 else { return nil }
            return ArchiveSyncRetryCategoryCount(category: category, count: count)
        }
    }

    static func requiresAttention(
        _ reasons: [EngramServiceArchiveV2RetryReasonCount]
    ) -> Bool {
        reasons.contains { category(for: $0.symbol) != .network }
    }

    static func requiresAttention(symbol: String) -> Bool {
        category(for: symbol) != .network
    }

    static func category(for symbol: String) -> ArchiveSyncRetryCategory {
        if symbol.hasPrefix("transport_")
            || symbol == "remote_server_unavailable"
            || symbol == "remote_rate_limited" {
            return .network
        }
        if symbol == "remote_auth_rejected" {
            return .credentials
        }
        if symbol.hasPrefix("local_") {
            return .localArchive
        }
        if symbol.hasPrefix("remote_") {
            return .remoteVerification
        }
        if symbol == "replica_configuration_failure" {
            return .configuration
        }
        return .other
    }
}

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

        let replicationNeedsAttention = status.lastReplicationError.map(
            ArchiveSyncRetryPresentation.requiresAttention(symbol:)
        ) ?? false
        let retryNeedsAttention = status.replicas.contains {
            ArchiveSyncRetryPresentation.requiresAttention($0.retryReasons)
        }
        let hasAttentionState = status.configurationError != nil
            || status.lastCaptureError != nil
            || replicationNeedsAttention
            || retryNeedsAttention
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

enum ArchiveSyncSchedulerPresentation {
    static func priorityLine(_ priority: String) -> String? {
        switch priority {
        case "remote":
            String(localized: "Next pass starts with remote replication")
        case "local":
            String(localized: "Next pass starts with local capture and indexing")
        default:
            nil
        }
    }

    static func pauseLine(
        replicaID: String,
        pauseReason: String?,
        pausedUntil: String?,
        localizedTimestamp: (String) -> String
    ) -> String? {
        guard let pauseReason else { return nil }
        switch pauseReason {
        case "transientInfrastructureBackoff":
            guard let pausedUntil else { return nil }
            return String.localizedStringWithFormat(
                String(localized: "%@ temporarily paused until %@"),
                replicaID.uppercased(),
                localizedTimestamp(pausedUntil)
            )
        case "needsAttention":
            return String.localizedStringWithFormat(
                String(localized: "%@ paused — needs attention"),
                replicaID.uppercased()
            )
        default:
            return nil
        }
    }
}

enum ArchiveRemoteTelemetryPresentation {
    static func summary(
        replicaID: String,
        telemetry: EngramServiceArchiveV2RemoteTelemetry?,
        error: String?
    ) -> String {
        let replicaName = replicaID.uppercased()
        guard let telemetry else {
            var parts = [
                replicaName,
                String(localized: "Remote status unavailable"),
            ]
            if let error {
                parts.append(remoteErrorName(error))
            }
            return parts.joined(separator: " · ")
        }

        let build = telemetry.sourceRevision == "unknown"
            ? String(localized: "Unknown build")
            : String(telemetry.sourceRevision.prefix(8))
        var parts = [
            replicaName,
            String(localized: "Online"),
            formatted("Build: %@", build),
            formatted("Snapshot: %@", localizedTimestamp(telemetry.snapshotAt)),
            uptimeSummary(telemetry.uptimeSeconds),
            diskSummary(available: telemetry.diskAvailableBytes, total: telemetry.diskTotalBytes),
            telemetry.lastArchiveMutationAt.map {
                formatted("Last write: %@", localizedTimestamp($0))
            } ?? String(localized: "Last write: none"),
            formatted("Requests: %lld", telemetry.requestCount),
            formatted("Client errors: %lld", telemetry.clientErrorCount),
            formatted("Server errors: %lld", telemetry.serverErrorCount),
            telemetry.recentErrors.last.map {
                formatted("Latest error: %@", errorCategoryName($0.category))
            } ?? String(localized: "Latest error: none"),
        ]
        if telemetry.persistenceError != nil {
            parts.append(
                formatted("Persistence: %@", String(localized: "Snapshot persistence failed"))
            )
        }
        return parts.joined(separator: " · ")
    }

    static func remoteErrorName(_ symbol: String?) -> String {
        switch symbol {
        case "transport_network":
            String(localized: "Network error")
        case "transport_timeout":
            String(localized: "Request timed out")
        case "transport_tls":
            String(localized: "TLS error")
        case "transport_cancelled":
            String(localized: "Request cancelled")
        case "remote_telemetry_unavailable":
            String(localized: "Remote telemetry unavailable")
        case "telemetry_unsupported":
            String(localized: "Telemetry unsupported")
        case "final_url_mismatch", "invalid_canonical_response", "invalid_request",
             "not_http_response", "redirect_rejected", "response_too_large",
             "unexpected_status":
            String(localized: "Invalid remote response")
        default:
            String(localized: "Other remote error")
        }
    }

    static func errorCategoryName(_ category: String) -> String {
        switch category {
        case "unauthorized": String(localized: "Unauthorized")
        case "malformed_request": String(localized: "Malformed request")
        case "not_found": String(localized: "Not found")
        case "conflict": String(localized: "Conflict")
        case "payload_too_large": String(localized: "Payload too large")
        case "invalid_content": String(localized: "Invalid content")
        case "storage_unavailable": String(localized: "Storage unavailable")
        case "internal_error": String(localized: "Internal server error")
        default: String(localized: "Other remote error")
        }
    }

    private static func diskSummary(available: Int64?, total: Int64?) -> String {
        guard let available else { return String(localized: "Disk free: unavailable") }
        let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .binary)
        guard let total else { return formatted("Disk free: %@", availableText) }
        return formatted(
            "Disk free: %@ of %@",
            availableText,
            ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
        )
    }

    private static func uptimeSummary(_ seconds: Double) -> String {
        let minuteValue = seconds / 60
        guard minuteValue < Double(Int64.max) else {
            return String(localized: "Uptime unavailable")
        }
        return formatted("Uptime: %@", localizedUptime(minutes: Int64(minuteValue)))
    }

    private static func localizedUptime(minutes: Int64) -> String {
        let days = minutes / (24 * 60)
        let hours = (minutes / 60) % 24
        if days > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%lld d, %lld hr"),
                days,
                hours
            )
        }
        let remainingMinutes = minutes % 60
        if hours > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%lld hr, %lld min"),
                hours,
                remainingMinutes
            )
        }
        return formatted("%lld min", minutes)
    }

    private static func localizedTimestamp(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .numeric, time: .shortened) ?? value
    }

    private static func formatted(_ key: String.LocalizationValue, _ value: CVarArg) -> String {
        String.localizedStringWithFormat(String(localized: key), value)
    }

    private static func formatted(
        _ key: String.LocalizationValue,
        _ first: CVarArg,
        _ second: CVarArg
    ) -> String {
        String.localizedStringWithFormat(String(localized: key), first, second)
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

                    Text(backlogDrainStateSummary(archiveStatus.drainState))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("archiveSync_drainState")

                    if let priorityLine = ArchiveSyncSchedulerPresentation.priorityLine(
                        archiveStatus.nextPassPriority
                    ) {
                        Text(priorityLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("archiveSync_nextPassPriority")
                    }

                    if !archiveStatus.activeStages.isEmpty {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Active stages: %@"),
                                ListFormatter.localizedString(
                                    byJoining: archiveStatus.activeStages.map(backlogDrainStageName)
                                )
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("archiveSync_activeStages")
                    }

                    if let pass = archiveStatus.lastDrainPass {
                        Text(lastDrainPassSummary(pass))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("archiveSync_lastDrainPass")
                    }

                    if let nextWake = archiveStatus.nextWakeAt {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Next backlog wake around %@"),
                                localizedTimestamp(nextWake)
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("archiveSync_nextWake")
                    }

                    if let cycle = archiveStatus.lastReplicationCycle {
                        Text(lastCycleSummary(cycle))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("archiveSync_lastCycle")
                    }

                    ForEach(archiveStatus.replicas, id: \.replicaID) { replica in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(replicaSummary(replica))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(
                                    replica.replicaID == "hq" ? "archiveSync_hq" : "archiveSync_m1"
                                )
                            if let pauseLine = ArchiveSyncSchedulerPresentation.pauseLine(
                                replicaID: replica.replicaID,
                                pauseReason: replica.pauseReason,
                                pausedUntil: replica.pausedUntil,
                                localizedTimestamp: localizedTimestamp
                            ) {
                                Text(pauseLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier(
                                        replica.replicaID == "hq"
                                            ? "archiveSync_hqPause"
                                            : "archiveSync_m1Pause"
                                    )
                            }
                            if let diagnostics = replicaDiagnostics(replica) {
                                Text(diagnostics)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityIdentifier(
                                        replica.replicaID == "hq"
                                            ? "archiveSync_hqDiagnostics"
                                            : "archiveSync_m1Diagnostics"
                                    )
                            }
                            Text(
                                ArchiveRemoteTelemetryPresentation.summary(
                                    replicaID: replica.replicaID,
                                    telemetry: replica.remoteTelemetry,
                                    error: replica.remoteTelemetryError
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityIdentifier(
                                replica.replicaID == "hq"
                                    ? "archiveSync_hqRemoteTelemetry"
                                    : "archiveSync_m1RemoteTelemetry"
                            )
                        }
                    }

                    if let next = archiveStatus.nextScheduledCycleAt {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "Next background opportunity around %@"),
                                localizedTimestamp(next)
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("archiveSync_nextCycle")
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

    private func replicaDiagnostics(
        _ replica: EngramServiceArchiveV2ReplicaStatus
    ) -> String? {
        var parts: [String] = []
        if let oldest = replica.oldestOutstandingAt {
            parts.append(
                String.localizedStringWithFormat(
                    String(localized: "Oldest pending: %@"),
                    localizedTimestamp(oldest)
                )
            )
        }
        if let retry = replica.nextRetryAt {
            parts.append(
                String.localizedStringWithFormat(
                    String(localized: "Next retry: %@"),
                    localizedTimestamp(retry)
                )
            )
        }
        let reasons = ArchiveSyncRetryPresentation.group(replica.retryReasons).map {
            "\($0.category.localizedName) ×\($0.count)"
        }
        if !reasons.isEmpty {
            parts.append(
                String.localizedStringWithFormat(
                    String(localized: "Retry reasons: %@"),
                    ListFormatter.localizedString(byJoining: reasons)
                )
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func lastCycleSummary(
        _ cycle: EngramServiceArchiveV2ReplicationCycleSummary
    ) -> String {
        var summary = String.localizedStringWithFormat(
            String(localized: "Last pass %@ · %@ · verified %lld · retry %lld · quarantined %lld"),
            localizedTimestamp(cycle.finishedAt),
            localizedDuration(milliseconds: cycle.durationMs),
            Int64(cycle.verifiedCount),
            Int64(cycle.retryScheduledCount),
            Int64(cycle.quarantinedCount)
        )
        if let error = cycle.cycleError {
            summary += " · " + String.localizedStringWithFormat(
                String(localized: "Issue: %@"),
                ArchiveSyncRetryPresentation.category(for: error).localizedName
            )
        }
        if cycle.cancelled {
            summary += " · " + String(localized: "Cancelled")
        }
        return summary
    }

    private func backlogDrainStateSummary(_ state: String) -> String {
        switch state {
        case "draining":
            return String(localized: "Backlog drain: Draining")
        case "waitingRetry":
            return String(localized: "Backlog drain: Waiting to retry")
        case "pausedLowPower":
            return String(localized: "Backlog drain: Paused for Low Power Mode")
        case "pausedThermal":
            return String(localized: "Backlog drain: Paused for thermal pressure")
        case "needsAttention":
            return String(localized: "Backlog drain: Needs attention")
        default:
            return String(localized: "Backlog drain: Idle")
        }
    }

    private func backlogDrainStageName(_ stage: String) -> String {
        switch stage {
        case "capture": String(localized: "Capture")
        case "indexing": String(localized: "Indexing")
        case "binding": String(localized: "Binding")
        case "policy": String(localized: "Policy")
        case "hq": String(localized: "HQ replication")
        case "m1": String(localized: "M1 replication")
        default: stage
        }
    }

    private func lastDrainPassSummary(_ pass: EngramServiceArchiveV2DrainPassSummary) -> String {
        var summary = String.localizedStringWithFormat(
            String(localized: "Last backlog pass %@ · %@ · captured %lld · bound %lld · policy %lld · HQ %lld · M1 %lld"),
            localizedTimestamp(pass.finishedAt),
            localizedDuration(milliseconds: pass.durationMs),
            Int64(pass.capturedFiles),
            Int64(pass.boundRows),
            Int64(pass.policyRows),
            Int64(pass.hqVerified),
            Int64(pass.m1Verified)
        )
        if pass.cancelled {
            summary += " · " + String(localized: "Cancelled")
        }
        return summary
    }

    private func localizedTimestamp(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return value }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func localizedDuration(milliseconds: Double) -> String {
        if milliseconds < 1_000 {
            return String.localizedStringWithFormat(
                String(localized: "%lld ms"),
                Int64(milliseconds.rounded())
            )
        }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        let seconds = formatter.string(from: NSNumber(value: milliseconds / 1_000))
            ?? String(format: "%.1f", milliseconds / 1_000)
        return String.localizedStringWithFormat(String(localized: "%@ s"), seconds)
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

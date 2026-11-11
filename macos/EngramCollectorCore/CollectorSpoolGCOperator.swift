import Foundation

/// Explicit offline operator entry. No service control or credential/transport
/// capability; the operator separately stops the collector before taking its lock.
public enum CollectorSpoolGCOperator {
    public static func run(settingsURL: URL, action: String, runID: String? = nil,
                           approvalURL: URL? = nil, approvedSHA256: String? = nil) throws -> Data {
        guard ["apply", "restore", "finalize"].contains(action) else { throw CollectorSpoolGCError.invalidInput }
        let now = Int64(Date().timeIntervalSince1970)
        let approval: CollectorSpoolGCApproval?
        if action == "restore" {
            guard let runID, UUID(uuidString: runID) != nil, approvalURL == nil, approvedSHA256 == nil else {
                throw CollectorSpoolGCError.invalidInput
            }
            approval = nil
        } else {
            guard let approvalURL, let approvedSHA256 else { throw CollectorSpoolGCError.proofMissing }
            approval = try CollectorSpoolGCApproval.load(approvalURL, approvedSHA256: approvedSHA256).0
            try approval!.validateTime(now: now)
            guard approval!.action == action, action != "finalize" || runID == approval!.runID else {
                throw CollectorSpoolGCError.invalidEvidence
            }
        }
        guard let config = try CollectorRuntimeConfiguration.load(at: settingsURL) else { throw CollectorSpoolGCError.invalidInput }
        let owner: CollectorInventoryOwner
        do {
            guard let acquired = try CollectorInventoryOwner.open(enabled: true, shadowRoot: config.shadowURL,
                identityCatalog: config.identityURL, ownerRunID: UUID().uuidString) else { throw CollectorSpoolGCError.invalidInput }
            owner = acquired
        } catch CollectorInventoryOwnerError.alreadyOwned { throw CollectorSpoolGCError.busy }
        defer { try? owner.close() }
        let catalog = try CollectorRuntime.openExistingCapture(config, machineID: owner.machineIdentity())
        defer { try? catalog.close() }
        let session = try CollectorSpoolGCSession(owner: owner, catalog: catalog, spoolRoot: config.shadowURL)
        let report: CollectorSpoolGCSession.ExecutionReport
        if action == "restore" {
            var restored = CollectorSpoolGCSession.ExecutionReport(runID: runID!, action: "restore")
            restored.restoredObjects = try session.restore(runID: runID!, now: now)
            report = restored
        } else {
            _ = try session.recover(now: now, inspectUntracked: true)
            report = action == "apply" ? try session.apply(approval: approval, settingsURL: settingsURL, now: now)
                : try session.finalize(approval: approval, settingsURL: settingsURL, now: now)
        }
        return try ArchiveCanonicalJSON.encode(report)
    }
}

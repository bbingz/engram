import Foundation
import EngramCoreRead
import EngramCoreWrite

protocol ServiceAIAuditRecording: Sendable {
    func record(_ entry: ServiceAIAuditEntry) async
}

struct ServiceAIAuditEntry: Sendable {
    var caller: String
    var operation: String
    var method: String?
    var url: String?
    var statusCode: Int64?
    var durationMs: Int64?
    var model: String?
    var provider: String?
    var promptTokens: Int64?
    var completionTokens: Int64?
    var totalTokens: Int64?
    var error: String?
    var sessionId: String?
    var requestBody: String?
    var responseBody: String?
}

struct ServiceAIAuditRecorder: ServiceAIAuditRecording, Sendable {
    let writerGate: ServiceWriterGate
    let auditConfig: @Sendable () -> EngramServiceCommandHandler.ServiceAISettings.AuditConfig

    init(
        writerGate: ServiceWriterGate,
        auditConfig: @escaping @Sendable () -> EngramServiceCommandHandler.ServiceAISettings.AuditConfig = {
            EngramServiceCommandHandler.ServiceAISettings.readAuditConfig()
        }
    ) {
        self.writerGate = writerGate
        self.auditConfig = auditConfig
    }

    func record(_ entry: ServiceAIAuditEntry) async {
        let audit = auditConfig()
        guard audit.enabled else { return }
        let requestBody = audit.logBodies ? Self.boundedBody(entry.requestBody, max: audit.maxBodySize) : nil
        let responseBody = audit.logBodies ? Self.boundedBody(entry.responseBody, max: audit.maxBodySize) : nil
        do {
            _ = try await writerGate.performWriteCommand(name: "aiAuditRecord") { writer in
                try writer.write { db in
                    guard try db.tableExists("ai_audit_log") else { return }
                    try db.execute(sql: """
                        INSERT INTO ai_audit_log(
                            caller, operation, method, url, status_code, duration_ms, model, provider,
                            prompt_tokens, completion_tokens, total_tokens, request_body, response_body,
                            error, session_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                        entry.caller, entry.operation, entry.method, entry.url, entry.statusCode,
                        entry.durationMs, entry.model, entry.provider, entry.promptTokens,
                        entry.completionTokens, entry.totalTokens, requestBody, responseBody,
                        Self.boundedError(entry.error), entry.sessionId
                    ])
                }
            }
        } catch {
            ServiceLogger.error("AI audit record failed", category: .ai, error: error)
        }
    }

    private static func boundedBody(_ value: String?, max: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let redacted = TranscriptRedactionPolicy.redact(value)
        if redacted.utf8.count <= max { return redacted }
        return String(decoding: Data(redacted.utf8.prefix(max)), as: UTF8.self) + "...[truncated]"
    }

    private static func boundedError(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var text = TranscriptRedactionPolicy.redact(value)
        if text.utf8.count > 1024 {
            text = String(decoding: Data(text.utf8.prefix(1024)), as: UTF8.self)
        }
        return text.isEmpty ? nil : text
    }
}

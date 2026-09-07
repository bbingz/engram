import Foundation

public struct SourceMetadataProjection: Sendable {
    public enum Format: Equatable, Sendable {
        case claudeCode(forceClaudeCodeSource: Bool)
        case codex
    }

    public enum SelectionChange: Equatable, Sendable {
        case none
        case codexMetadata
    }

    public private(set) var nativeSessionID: String?
    public private(set) var cwd: String?
    public private(set) var model: String?
    public private(set) var selectedCodexMetadata = false
    public private(set) var hasConflictingRoots = false
    public private(set) var hasConflictingIdentities = false
    public private(set) var hasConflictingSources = false
    public private(set) var hasInvalidRootEvidence = false
    public private(set) var hasInvalidIdentityEvidence = false
    public private(set) var sawRecognizedRecord = false

    private let format: Format
    private let locator: String
    private var firstObservedRoot: String?
    private var firstObservedIdentity: String?
    private var firstObservedSource: SourceName?

    public var source: SourceName {
        switch format {
        case .codex: .codex
        case .claudeCode(let forceClaudeCodeSource):
            forceClaudeCodeSource ? .claudeCode : Self.claudeSource(model: model ?? "", filePath: locator)
        }
    }

    public init(format: Format, locator: String) {
        self.format = format
        self.locator = locator
    }

    /// Selection matches the product parsers. Conflict flags are additional
    /// conservative evidence for upload eligibility, not parser rejection rules.
    @discardableResult
    public mutating func consume(_ object: [String: Any]) -> SelectionChange {
        let type = object["type"] as? String
        switch format {
        case .claudeCode(let forceClaudeCodeSource):
            observeIdentity(object["sessionId"])
            if nativeSessionID == nil, let value = object["sessionId"] as? String, !value.isEmpty {
                nativeSessionID = value
            }
            if type == "session_meta", object["payload"] is [String: Any] {
                hasConflictingSources = true
            }
            guard type == "user" || type == "assistant" else { return .none }
            sawRecognizedRecord = true
            observeRoot(object["cwd"])
            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
            let message = object["message"] as? [String: Any]
            if let value = message?["model"] as? String, !value.isEmpty {
                if model == nil { model = value }
                let observed: SourceName = forceClaudeCodeSource
                    ? .claudeCode : Self.claudeSource(model: value, filePath: locator)
                if let firstObservedSource, firstObservedSource != observed { hasConflictingSources = true }
                if firstObservedSource == nil { firstObservedSource = observed }
            }
            return .none
        case .codex:
            if (type == "user" || type == "assistant"), object["sessionId"] != nil {
                hasConflictingSources = true
            }
            guard type == "session_meta" else { return .none }
            sawRecognizedRecord = true
            guard let payload = object["payload"] as? [String: Any] else {
                hasInvalidIdentityEvidence = true
                return .none
            }
            observeIdentity(payload["id"])
            observeRoot(payload["cwd"])
            guard !selectedCodexMetadata else { return .none }
            selectedCodexMetadata = true
            nativeSessionID = payload["id"] as? String
            cwd = payload["cwd"] as? String
            return .codexMetadata
        }
    }

    public static func claudeSource(model: String, filePath: String? = nil) -> SourceName {
        if let filePath, hasLobsterAIPathComponent(filePath) { return .lobsterai }
        if model.isEmpty || model.hasPrefix("claude") || model.hasPrefix("<") { return .claudeCode }
        if model.lowercased().contains("minimax") { return .minimax }
        return .claudeCode
    }

    static func hasLobsterAIPathComponent(_ filePath: String) -> Bool {
        filePath.components(separatedBy: CharacterSet(charactersIn: "/\\")).contains { component in
            let lowercased = component.lowercased()
            return lowercased == "lobsterai" || lowercased == ".lobsterai"
                || lowercased.hasPrefix("lobsterai-") || lowercased.hasPrefix("lobsterai_")
                || lowercased.hasPrefix("lobsterai.") || lowercased.hasPrefix(".lobsterai-")
                || lowercased.hasPrefix(".lobsterai_") || lowercased.hasPrefix(".lobsterai.")
        }
    }

    /// Lexical validation only. The collector separately rejects filesystem
    /// aliases; product parser selection does not acquire new filesystem reads.
    static func normalizedProjectRoot(_ value: String) -> String? {
        guard value.hasPrefix("/"), value != "/", !value.utf8.contains(0) else { return nil }
        let normalized = URL(fileURLWithPath: value).standardizedFileURL.path
        return normalized == value ? normalized : nil
    }

    private mutating func observeRoot(_ value: Any?) {
        guard let value else { return }
        guard let string = value as? String else { hasInvalidRootEvidence = true; return }
        guard !string.isEmpty else { return }
        guard let normalized = Self.normalizedProjectRoot(string) else { hasInvalidRootEvidence = true; return }
        if let firstObservedRoot, firstObservedRoot != normalized { hasConflictingRoots = true }
        if firstObservedRoot == nil { firstObservedRoot = normalized }
    }

    private mutating func observeIdentity(_ value: Any?) {
        guard let value else { return }
        guard let string = value as? String else { hasInvalidIdentityEvidence = true; return }
        guard !string.isEmpty else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || string.utf8.contains(0) {
            hasInvalidIdentityEvidence = true
        }
        if let firstObservedIdentity, !firstObservedIdentity.utf8.elementsEqual(string.utf8) {
            hasConflictingIdentities = true
        }
        if firstObservedIdentity == nil { firstObservedIdentity = string }
    }
}

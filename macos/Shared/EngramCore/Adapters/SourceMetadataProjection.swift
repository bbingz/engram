import Foundation

public struct SourceMetadataProjection: Sendable {
    public enum Format: Equatable, Sendable {
        case claudeCode(forceClaudeCodeSource: Bool)
        case codex
        case qwen
        case qoder
        case iflow
        case cline
        case commandcode
        case copilot
        case geminiCli
        case opencode
        case kimi
        case cursor
        case vscode
        case windsurfHookTranscript
        case antigravityCLITranscript
        case pi
        case grok
    }

    public static let antigravityCLIPrefixByteLimit = 50_000

    public static func antigravityCLINativeID(logicalLocator: String) -> String? {
        guard let normalized = ArchiveSourceDescriptor.fileSetAbsolutePath(logicalLocator),
              normalized.utf8.elementsEqual(logicalLocator.utf8) else { return nil }
        let parts = logicalLocator.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts.suffix(3) == [".system_generated", "logs", "transcript.jsonl"] else { return nil }
        let id = String(parts[parts.count - 4])
        return id.isEmpty || id == "." || id == ".." ? nil : id
    }

    /// Decode only the captured byte prefix. A short complete file cannot hide
    /// invalid UTF-8 by dropping its tail; only a valid incomplete scalar at
    /// the full prefix cap may be omitted when more source bytes exist.
    public static func antigravityCLIPrefixMetadata(
        _ prefix: Data, hasMoreBytes: Bool
    ) -> (cwd: String, observedProjectRoots: [String])? {
        guard prefix.count <= antigravityCLIPrefixByteLimit,
              !hasMoreBytes || prefix.count == antigravityCLIPrefixByteLimit else { return nil }
        if let text = String(data: prefix, encoding: .utf8) { return antigravityCLIPathMetadata(in: text) }
        guard hasMoreBytes else { return nil }
        for count in 1...3 where prefix.count >= count {
            let tail = Array(prefix.suffix(count))
            let lead = tail[0]
            let width: Int
            switch lead {
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: continue
            }
            guard count < width, tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { continue }
            if count > 1 {
                let second = tail[1]
                if (lead == 0xE0 && second < 0xA0) || (lead == 0xED && second > 0x9F)
                    || (lead == 0xF0 && second < 0x90) || (lead == 0xF4 && second > 0x8F) { continue }
            }
            if let text = String(data: prefix.dropLast(count), encoding: .utf8) {
                return antigravityCLIPathMetadata(in: text)
            }
        }
        return nil
    }

    static func antigravityCLIPathMetadata(in text: String) -> (cwd: String, observedProjectRoots: [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"(/(?:[^/\s"'`]+/)+)[^/\s"'`]+"#) else { return ("", []) }
        var counts: [String: Int] = [:]
        var roots: [String] = []
        var seen = Set<Data>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { continue }
            var directory = String(text[range])
            if directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
            counts[directory, default: 0] += 1
            if seen.insert(Data(directory.utf8)).inserted { roots.append(directory) }
        }
        let cwd = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first?.key ?? ""
        return (cwd, roots)
    }

    struct CursorModernMetadata {
        let metadata: [String: Any]
        let cwd: String
        let observedRawCWDs: [String]
        let hasInvalidRootEvidence: Bool
        let hasMalformedMetadata: Bool
    }

    /// Both inputs belong to an existing modern store; no-store sessions supply neither.
    static func cursorModernMetadata(storedText: String?, liveText: String?) -> CursorModernMetadata {
        var stored: [String: Any] = [:]
        var live: [String: Any] = [:]
        var malformed = false
        if let storedText {
            // Match native hex-first decoding. Valid hex that is not a JSON
            // object is not retried as UTF-8, unwrapped or coerced.
            let data = cursorDataFromHex(storedText) ?? Data(storedText.utf8)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { stored = object }
            else { malformed = true }
        }
        if let liveText {
            if let object = try? JSONSerialization.jsonObject(with: Data(liveText.utf8)) as? [String: Any] { live = object }
            else { malformed = true }
        }
        var roots: [String] = []
        var seen = Set<Data>()
        var invalidRoot = false
        for object in [stored, live] {
            guard let value = object["cwd"] else { continue }
            if let root = value as? String {
                if seen.insert(Data(root.utf8)).inserted { roots.append(root) }
            } else { invalidRoot = true }
        }
        var metadata = stored
        // The native live overlay includes empty/null/non-String values. It
        // must not revive a stored cwd or summary after an explicit override.
        metadata.merge(live) { _, liveValue in liveValue }
        let cwd = (metadata["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CursorModernMetadata(metadata: metadata, cwd: cwd, observedRawCWDs: roots,
            hasInvalidRootEvidence: invalidRoot, hasMalformedMetadata: malformed)
    }

    private static func cursorDataFromHex(_ string: String) -> Data? {
        guard string.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    public enum SelectionChange: Equatable, Sendable {
        case none
        case codexMetadata
    }

    public private(set) var nativeSessionID: String?
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
    private var selectedCwd: String?
    private var firstObservedRoot: String?
    private var firstObservedIdentity: String?
    private var firstObservedSource: SourceName?
    private var expectedCodexAncestorIDs: Set<Data> = []
    private var vscodeSawInitial = false
    private var vscodeRootIsObject = false
    private var vscodeSelectedID: String?

    public var source: SourceName {
        switch format {
        case .codex: .codex
        case .qwen: .qwen
        case .qoder: .qoder
        case .iflow: .iflow
        case .cline: .cline
        case .commandcode: .commandcode
        case .copilot: .copilot
        case .geminiCli: .geminiCli
        case .opencode: .opencode
        case .kimi: .kimi
        case .cursor: .cursor
        case .vscode: .vscode
        case .windsurfHookTranscript: .windsurf
        case .antigravityCLITranscript: .antigravity
        case .pi: .pi
        case .grok: .grok
        case .claudeCode(let forceClaudeCodeSource):
            forceClaudeCodeSource ? .claudeCode : Self.claudeSource(model: model ?? "", filePath: locator)
        }
    }

    /// CommandCode slug decode is a post-record fallback only. Reading `.cwd`
    /// after consume sees it; an earlier fallback must not hide a later explicit cwd.
    public var cwd: String? {
        if let selectedCwd { return selectedCwd }
        return commandCodeDirectoryFallback()
    }

    public init(format: Format, locator: String) {
        self.format = format
        self.locator = locator
        if format == .cline { nativeSessionID = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent }
        if format == .windsurfHookTranscript { nativeSessionID = ArchiveSourceDescriptor.windsurfHookNativeID(logicalLocator: locator) }
        if format == .antigravityCLITranscript { nativeSessionID = Self.antigravityCLINativeID(logicalLocator: locator) }
    }

    /// Selection matches the product parsers. Conflict flags are additional
    /// conservative evidence for upload eligibility, not parser rejection rules.
    @discardableResult
    public mutating func consume(_ object: [String: Any]) -> SelectionChange {
        let type = object["type"] as? String
        switch format {
        case .windsurfHookTranscript:
            // Hook workspace evidence requires a dedicated privacy pass; do not infer cwd.
            return .none
        case .antigravityCLITranscript:
            // CLI identity is path-derived; cwd comes from bounded raw bytes.
            return .none
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
            if selectedCwd == nil, let value = Self.recognizedClaudeCodeCWD(from: object) { selectedCwd = value }
            let message = object["message"] as? [String: Any]
            if let value = message?["model"] as? String, !value.isEmpty {
                if model == nil { model = value }
                // Exact "<synthetic>" is a placeholder, not a second provider.
                if !value.utf8.elementsEqual("<synthetic>".utf8) {
                    let observed: SourceName = forceClaudeCodeSource
                        ? .claudeCode : Self.claudeSource(model: value, filePath: locator)
                    if let firstObservedSource, firstObservedSource != observed { hasConflictingSources = true }
                    if firstObservedSource == nil { firstObservedSource = observed }
                }
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
            if !selectedCodexMetadata {
                observeIdentity(payload["id"])
                observeRoot(payload["cwd"])
                selectedCodexMetadata = true
                nativeSessionID = payload["id"] as? String
                selectedCwd = payload["cwd"] as? String
                noteCodexAncestorPointer(payload["forked_from_id"])
                return .codexMetadata
            }
            observeRoot(payload["cwd"])
            if isExpectedCodexAncestor(payload["id"]) {
                noteCodexAncestorPointer(payload["forked_from_id"])
                return .none
            }
            observeIdentity(payload["id"])
            return .none
        case .qwen:
            observeIdentity(object["sessionId"])
            if nativeSessionID == nil, let value = object["sessionId"] as? String, !value.isEmpty {
                nativeSessionID = value
            }
            guard type == "user" || type == "assistant" || type == "tool_result" else { return .none }
            sawRecognizedRecord = true
            observeRoot(object["cwd"])
            if selectedCwd == nil, let value = object["cwd"] as? String, !value.isEmpty { selectedCwd = value }
            if model == nil, let value = object["model"] as? String { model = value }
            return .none
        case .qoder, .iflow:
            guard type == "user" || type == "assistant" else { return .none }
            sawRecognizedRecord = true
            observeIdentity(object["sessionId"])
            if nativeSessionID == nil, let value = object["sessionId"] as? String, !value.isEmpty {
                nativeSessionID = value
            }
            observeRoot(object["cwd"])
            if selectedCwd == nil, let value = object["cwd"] as? String, !value.isEmpty { selectedCwd = value }
            let message = object["message"] as? [String: Any]
            if model == nil, let value = message?["model"] as? String { model = value }
            return .none
        case .commandcode:
            guard let role = object["role"] as? String,
                  role == "user" || role == "assistant" || role == "tool"
            else { return .none }
            sawRecognizedRecord = true
            observeIdentity(object["sessionId"])
            if nativeSessionID == nil, let value = object["sessionId"] as? String, !value.isEmpty {
                nativeSessionID = value
            }
            observeRoot(object["cwd"])
            if selectedCwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
                selectedCwd = value
            }
            if model == nil, let value = object["model"] as? String { model = value }
            if model == nil, let value = (object["metadata"] as? [String: Any])?["model"] as? String {
                model = value
            }
            return .none
        case .cline:
            if model == nil, let value = (object["modelInfo"] as? [String: Any])?["modelId"] as? String { model = value }
            if let say = object["say"] as? String, ["task", "user_feedback", "text", "api_req_started"].contains(say) {
                sawRecognizedRecord = true
            }
            if let value = Self.clineCWD(from: object) {
                observeRoot(value)
                if value.isEmpty { hasInvalidRootEvidence = true }
                if selectedCwd == nil { selectedCwd = value }
            }
            return .none
        case .vscode:
            consumeVSCodeIdentity(object)
            return .none
        case .pi:
            if type == "session" {
                sawRecognizedRecord = true
                observeIdentity(object["id"])
                if nativeSessionID == nil, let value = object["id"] as? String, !value.isEmpty {
                    nativeSessionID = value
                }
                observeRoot(object["cwd"])
                if selectedCwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
                    selectedCwd = value
                }
                return .none
            }
            if type == "message" {
                sawRecognizedRecord = true
            }
            return .none
        case .copilot, .geminiCli, .opencode, .kimi, .cursor, .grok:
            // Single-file JSONL consume is unsupported. Copilot identity is
            // taken from captured member bytes (YAML id/cwd, then events).
            return .none
        }
    }

    /// Tracks only root shape and the selected sessionId scalar. Requests and
    /// transcript content are never retained or reconstructed by the collector.
    private mutating func consumeVSCodeIdentity(_ object: [String: Any]) {
        let kind = (object["kind"] as? NSNumber)?.int64Value ?? (object["kind"] as? String).flatMap(Int64.init)
        guard let kind else { return }
        if kind == 0 {
            vscodeSawInitial = true
            let state = object["v"] as? [String: Any]
            vscodeRootIsObject = state != nil
            vscodeSelectedID = state?["sessionId"] as? String
        } else if vscodeSawInitial, (1...3).contains(kind), let path = object["k"] as? [Any] {
            guard path.count <= 64,
                  !path.contains(where: { (($0 as? NSNumber)?.int64Value ?? 0) > 1_000_000 }) else {
                hasInvalidIdentityEvidence = true
                return
            }
            guard let head = path.first else { return }
            if let key = head as? String {
                if !vscodeRootIsObject { vscodeSelectedID = nil }
                vscodeRootIsObject = true
                if key == "sessionId" {
                    if path.count == 1 {
                        vscodeSelectedID = kind == 1 ? object["v"] as? String : nil
                    } else if Self.vscodeMutatesContainer(path[1]) {
                        // A valid nested setter/push replaces the scalar with
                        // an object/array. Invalid/negative first steps are no-ops.
                        vscodeSelectedID = nil
                    }
                }
            } else if Self.vscodeMutatesContainer(head) {
                vscodeRootIsObject = false
                vscodeSelectedID = nil
            }
        }
        sawRecognizedRecord = vscodeSawInitial && vscodeRootIsObject
        nativeSessionID = sawRecognizedRecord
            ? vscodeSelectedID ?? URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent : nil
    }

    private static func vscodeMutatesContainer(_ value: Any) -> Bool {
        value is String || ((value as? NSNumber)?.int64Value).map { $0 >= 0 } == true
    }

    struct VSCodeWorkspaceMetadata {
        let cwd: String
        let observedProjectRoots: [String]
        let hasInvalidRootEvidence: Bool
    }

    /// Native first-folder selection plus every declared folder for privacy.
    /// Only frozen bytes are consulted; relative paths use the original config locator.
    static func vscodeWorkspaceMetadata(
        workspaceData: Data?, context: ArchiveVSCodeWorkspaceContext
    ) throws -> VSCodeWorkspaceMetadata {
        try context.validateWorkspaceData(workspaceData)
        guard let workspaceData,
              let workspace = try? JSONSerialization.jsonObject(with: workspaceData) as? [String: Any] else {
            return .init(cwd: "", observedProjectRoots: [], hasInvalidRootEvidence: true)
        }
        func decodeURI(_ uri: String) -> String {
            guard uri.hasPrefix("file://") else { return "" }
            var path = String(uri.dropFirst(7))
            if path.hasPrefix("localhost/") { path = String(path.dropFirst(9)) }
            return path.removingPercentEncoding ?? ""
        }
        if let folder = workspace["folder"] as? String {
            let cwd = decodeURI(folder)
            return .init(cwd: cwd, observedProjectRoots: [cwd], hasInvalidRootEvidence: cwd.isEmpty)
        }
        guard let locator = context.configurationLocator, let data = context.configurationData,
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = config["folders"] as? [Any] else {
            return .init(cwd: "", observedProjectRoots: [], hasInvalidRootEvidence: true)
        }
        var roots: [String] = []
        var invalid = false
        for item in folders {
            guard let folder = item as? [String: Any] else { invalid = true; continue }
            let cwd: String
            if let uri = folder["uri"] as? String {
                cwd = decodeURI(uri)
            } else if let path = folder["path"] as? String, !path.isEmpty {
                cwd = path.hasPrefix("/") ? path : URL(fileURLWithPath: locator)
                    .deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path
            } else { cwd = "" }
            if cwd.isEmpty { invalid = true }
            roots.append(cwd)
        }
        return .init(cwd: roots.first ?? "", observedProjectRoots: roots,
            hasInvalidRootEvidence: invalid || roots.isEmpty)
    }

    /// Recognized Claude Code user/assistant cwd only. Missing/empty ignored; validity is separate.
    static func recognizedClaudeCodeCWD(from object: [String: Any]) -> String? {
        let type = object["type"] as? String
        guard type == "user" || type == "assistant" else { return nil }
        guard let cwd = object["cwd"] as? String, !cwd.isEmpty else { return nil }
        return cwd
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

    /// Publication-only allowances for observed native working directories.
    /// The collector checks physical paths and project exclusions separately;
    /// policy configuration keeps the existing stricter normalizer.
    static func publicationProjectRoot(_ value: String, format: Format) -> String? {
        switch format {
        case .claudeCode, .codex, .geminiCli:
            if value == "/" { return "/" }
        case .pi, .qwen, .opencode:
            // Foundation abbreviates this physical directory to /tmp.
            if value == "/private/tmp" { return value }
        default:
            break
        }
        return normalizedProjectRoot(value)
    }

    private func commandCodeDirectoryFallback() -> String? {
        guard case .commandcode = format else { return nil }
        let decoded = Self.decodeCommandCodeDirectorySlug(locator)
        return Self.normalizedProjectRoot(decoded)
    }

    /// Single `-` → `/`, `--` → literal `-`. Same disambiguation as CommandCodeAdapter.
    private static func decodeCommandCodeDirectorySlug(_ locator: String) -> String {
        let encoded = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent
        guard encoded.contains("-") else { return "" }
        return encoded
            .replacingOccurrences(of: "--", with: "\u{0}")
            .replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "\u{0}", with: "-")
    }

    private mutating func observeRoot(_ value: Any?) {
        guard let value else { return }
        guard let string = value as? String else { hasInvalidRootEvidence = true; return }
        guard !string.isEmpty else { return }
        if let firstObservedRoot, firstObservedRoot.utf8.elementsEqual(string.utf8) { return }
        guard let normalized = Self.publicationProjectRoot(string, format: format) else { hasInvalidRootEvidence = true; return }
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

    private mutating func noteCodexAncestorPointer(_ value: Any?) {
        guard let value else { return }
        guard let string = value as? String else {
            hasInvalidIdentityEvidence = true
            return
        }
        guard !string.isEmpty else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || string.utf8.contains(0) {
            hasInvalidIdentityEvidence = true
            return
        }
        expectedCodexAncestorIDs.insert(Data(string.utf8))
    }

    private func isExpectedCodexAncestor(_ value: Any?) -> Bool {
        guard let string = value as? String, !string.isEmpty else { return false }
        return expectedCodexAncestorIDs.contains(Data(string.utf8))
    }
}


extension SourceMetadataProjection {
    static func clineCWD(from object: [String: Any]) -> String? {
        guard object["say"] as? String == "api_req_started", let text = object["text"] as? String,
              let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let request = payload["request"] as? String else { return nil }
        for pattern in [#"Current Working Directory \((.+?)\) Files"#, #"Current Working Directory \(([^)]+)\)"#] {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            let range = NSRange(request.startIndex..., in: request)
            if let match = regex.firstMatch(in: request, range: range),
               let capture = Range(match.range(at: 1), in: request) {
                let cwd = String(request[capture])
                return cwd.hasPrefix("Primary: ") ? "" : cwd
            }
        }
        return nil
    }

    enum ClineArrayError: Error, Equatable { case malformed, limitsExceeded }

    /// Incremental object-array framing. Retains at most one bounded record;
    /// strings, escapes and nested containers may cross arbitrary CAS chunks.
    struct ClineArrayReader {
        private enum State { case beforeArray, firstOrEnd, objectRequired, record, separatorOrEnd, done }
        private var state: State = .beforeArray
        private var pending = Data()
        private var depth = 0
        private var inString = false
        private var escaped = false
        private var records = 0
        let maximumRecordBytes: Int
        let maximumRecords: Int

        init(maximumRecordBytes: Int, maximumRecords: Int) {
            self.maximumRecordBytes = maximumRecordBytes
            self.maximumRecords = maximumRecords
        }

        mutating func consume(_ bytes: Data, onRecord: ([String: Any]) throws -> Void) throws {
            guard maximumRecordBytes > 0, maximumRecords > 0 else { throw ClineArrayError.limitsExceeded }
            for (index, byte) in bytes.enumerated() {
                if index & 4095 == 0 { try Task.checkCancellation() }
                if state == .record {
                    guard pending.count < maximumRecordBytes else { throw ClineArrayError.limitsExceeded }
                    pending.append(byte)
                    if inString {
                        if escaped { escaped = false }
                        else if byte == 92 { escaped = true }
                        else if byte == 34 { inString = false }
                        continue
                    }
                    if byte == 34 { inString = true; continue }
                    if byte == 123 || byte == 91 {
                        depth += 1
                        guard depth <= 128 else { throw ClineArrayError.limitsExceeded }
                    } else if byte == 125 || byte == 93 {
                        depth -= 1
                        if depth == 0 {
                            guard byte == 125,
                                  let object = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] else {
                                throw ClineArrayError.malformed
                            }
                            try onRecord(object)
                            pending.removeAll(keepingCapacity: true)
                            state = .separatorOrEnd
                        }
                    }
                    continue
                }
                if byte == 9 || byte == 10 || byte == 13 || byte == 32 { continue }
                switch state {
                case .beforeArray:
                    guard byte == 91 else { throw ClineArrayError.malformed }
                    state = .firstOrEnd
                case .firstOrEnd, .objectRequired:
                    if state == .firstOrEnd, byte == 93 { state = .done; continue }
                    guard byte == 123 else { throw ClineArrayError.malformed }
                    guard records < maximumRecords else { throw ClineArrayError.limitsExceeded }
                    records += 1
                    pending.append(byte); depth = 1; inString = false; escaped = false; state = .record
                case .separatorOrEnd:
                    if byte == 44 { state = .objectRequired }
                    else if byte == 93 { state = .done }
                    else { throw ClineArrayError.malformed }
                case .done, .record:
                    throw ClineArrayError.malformed
                }
            }
        }

        func finish() throws {
            guard state == .done else { throw ClineArrayError.malformed }
        }
    }
}

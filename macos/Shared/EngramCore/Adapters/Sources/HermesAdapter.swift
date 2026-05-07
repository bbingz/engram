import Foundation

final class HermesAdapter: SessionAdapter {
    let source: SourceName = .hermes
    private let sessionsRoot: URL
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/sessions")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        JSONLAdapterSupport.directChildren(of: sessionsRoot)
            .filter { $0.lastPathComponent.hasPrefix("session_") && $0.pathExtension == "json" }
            .map(\.path)
            .sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let object = try Phase4AdapterSupport.readJSONObject(locator: locator, limits: limits)
            guard let sessionId = JSONLAdapterSupport.string(object["session_id"]) else {
                return .failure(.malformedJSON)
            }
            let messages = JSONLAdapterSupport.array(object["messages"])?
                .compactMap { JSONLAdapterSupport.object($0) } ?? []
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var summary = ""

            for message in messages {
                let role = Self.normalizedRole(message["role"])
                let content = (JSONLAdapterSupport.string(message["content"]) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if role == "user" {
                    if content.isEmpty || Self.looksLikePreamble(content) {
                        systemCount += 1
                    } else {
                        userCount += 1
                        if summary.isEmpty { summary = content }
                    }
                } else if role == "assistant" {
                    assistantCount += 1
                    toolCount += Self.toolCalls(from: message).count
                } else if role == "tool" {
                    toolCount += 1
                } else if !role.isEmpty {
                    systemCount += 1
                }
            }

            let cwd = Self.normalizedPath(JSONLAdapterSupport.string(object["cwd"]))
                ?? Self.normalizedPath(JSONLAdapterSupport.string(JSONLAdapterSupport.object(object["model_config"])?["cwd"]))
                ?? ""
            let platform = (JSONLAdapterSupport.string(object["platform"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .hermes,
                    startTime: JSONLAdapterSupport.string(object["session_start"])
                        ?? Self.fileModifiedIso(locator),
                    endTime: JSONLAdapterSupport.string(object["last_updated"]),
                    cwd: cwd,
                    project: platform.isEmpty ? nil : platform,
                    model: JSONLAdapterSupport.string(object["model"]),
                    messageCount: userCount + assistantCount + toolCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: toolCount,
                    systemMessageCount: systemCount,
                    summary: summary.isEmpty ? "\(platform.isEmpty ? "Hermes" : platform) \(sessionId)" : String(summary.prefix(200)),
                    filePath: locator,
                    sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                    indexedAt: nil,
                    agentRole: nil,
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: nil,
                    suggestedParentId: nil
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        let object = try Phase4AdapterSupport.readJSONObject(locator: locator, limits: limits)
        let messages = JSONLAdapterSupport.array(object["messages"])?
            .compactMap { JSONLAdapterSupport.object($0) }
            .compactMap { Self.message(from: $0, timestamp: JSONLAdapterSupport.string(object["last_updated"]) ?? JSONLAdapterSupport.string(object["session_start"])) } ?? []
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject, timestamp: String?) -> NormalizedMessage? {
        let roleName = normalizedRole(object["role"])
        let role: NormalizedMessageRole
        if roleName == "user" {
            if let content = JSONLAdapterSupport.string(object["content"]), looksLikePreamble(content) {
                return nil
            }
            role = .user
        } else if roleName == "assistant" {
            role = .assistant
        } else if roleName == "tool" {
            role = .tool
        } else {
            return nil
        }
        let content = (JSONLAdapterSupport.string(object["content"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = role == .assistant ? toolCalls(from: object) : []
        guard !content.isEmpty || !calls.isEmpty else { return nil }
        return NormalizedMessage(
            role: role,
            content: content.isEmpty ? "[tool call]" : content,
            timestamp: timestamp,
            toolCalls: calls.isEmpty ? nil : calls,
            usage: nil
        )
    }

    private static func toolCalls(from message: JSONLAdapterSupport.JSONObject) -> [NormalizedToolCall] {
        guard let calls = JSONLAdapterSupport.array(message["tool_calls"]) else { return [] }
        return calls.compactMap { item in
            guard let call = JSONLAdapterSupport.object(item) else { return nil }
            let function = JSONLAdapterSupport.object(call["function"])
            let name = JSONLAdapterSupport.string(function?["name"]) ?? JSONLAdapterSupport.string(call["type"])
            guard let name, !name.isEmpty else { return nil }
            return NormalizedToolCall(name: name, input: JSONLAdapterSupport.string(function?["arguments"]))
        }
    }

    private static func normalizedRole(_ value: Any?) -> String {
        JSONLAdapterSupport.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return (value as NSString).expandingTildeInPath
    }

    private static func looksLikePreamble(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("[system: the user has invoked") ||
            lower.contains("[skill directory:") ||
            lower.contains("name: hermes-agent") ||
            lower.contains("resolve any relative paths in this skill")
    }

    private static func fileModifiedIso(_ locator: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: locator)
        let date = attrs?[.modificationDate] as? Date ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

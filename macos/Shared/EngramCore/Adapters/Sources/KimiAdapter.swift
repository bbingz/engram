import Foundation

final class KimiAdapter: SessionAdapter {
    let source: SourceName = .kimi
    private let sessionsRoot: URL
    private let kimiJsonPath: URL
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/sessions")
            .path,
        kimiJsonPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi/kimi.json")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot)
        self.kimiJsonPath = URL(fileURLWithPath: kimiJsonPath)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for workspaceURL in JSONLAdapterSupport.directChildren(of: sessionsRoot)
            where JSONLAdapterSupport.isDirectory(workspaceURL)
        {
            for sessionURL in JSONLAdapterSupport.directChildren(of: workspaceURL)
                where JSONLAdapterSupport.isDirectory(sessionURL)
            {
                let contextURL = sessionURL.appendingPathComponent("context.jsonl")
                if JSONLAdapterSupport.fileExists(contextURL.path) {
                    locators.append(contextURL.path)
                }
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let contextFiles = Self.contextFiles(for: locator)
            var allObjects: [Phase4AdapterSupport.JSONObject] = []
            var totalSize = Int64(0)
            for file in contextFiles {
                let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: file, limits: limits)
                if let failure { return .failure(failure) }
                allObjects.append(contentsOf: objects)
                totalSize += Phase4AdapterSupport.fileSize(file)
            }

            let messages = allObjects.filter(Self.isConversation)
            let userMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "user" }
            let assistantMessages = messages.filter { JSONLAdapterSupport.string($0["role"]) == "assistant" }
            let timestamps = try Self.readTimestamps(wirePath: URL(fileURLWithPath: locator)
                .deletingLastPathComponent()
                .appendingPathComponent("wire.jsonl")
                .path, limits: limits)
            let fileDate = (try? FileManager.default.attributesOfItem(atPath: locator)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let fallbackStart = ISO8601DateFormatter().string(from: fileDate.addingTimeInterval(-60))
            let firstUserText = JSONLAdapterSupport.string(userMessages.first?["content"]) ?? ""
            let sessionId = URL(fileURLWithPath: locator).deletingLastPathComponent().lastPathComponent

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .kimi,
                    startTime: timestamps.startTime.isEmpty ? fallbackStart : timestamps.startTime,
                    endTime: timestamps.endTime != timestamps.startTime ? timestamps.endTime : nil,
                    cwd: resolveCwd(sessionId: sessionId),
                    project: nil,
                    model: nil,
                    messageCount: userMessages.count + assistantMessages.count,
                    userMessageCount: userMessages.count,
                    assistantMessageCount: assistantMessages.count,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                    filePath: locator,
                    sizeBytes: totalSize,
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
        var messages: [NormalizedMessage] = []
        for file in Self.contextFiles(for: locator) {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: file, limits: limits)
            if let failure { throw failure }
            messages.append(contentsOf: objects.compactMap(Self.message(from:)))
        }
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func resolveCwd(sessionId: String) -> String {
        guard let data = try? Data(contentsOf: kimiJsonPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject,
              let workDirs = JSONLAdapterSupport.array(object["work_dirs"])
        else {
            return ""
        }
        for workDir in workDirs.compactMap({ JSONLAdapterSupport.object($0) }) {
            if JSONLAdapterSupport.string(workDir["last_session_id"]) == sessionId {
                return JSONLAdapterSupport.string(workDir["path"]) ?? ""
            }
        }
        return ""
    }

    private static func contextFiles(for locator: String) -> [String] {
        let url = URL(fileURLWithPath: locator)
        let directory = url.deletingLastPathComponent()
        var files = [locator]
        let subFiles = JSONLAdapterSupport.directChildren(of: directory)
            .filter {
                $0.lastPathComponent.hasPrefix("context_sub_") && $0.pathExtension == "jsonl"
            }
            .sorted {
                subContextIndex($0.lastPathComponent) < subContextIndex($1.lastPathComponent)
            }
            .map(\.path)
        files.append(contentsOf: subFiles)
        return files
    }

    private static func subContextIndex(_ filename: String) -> Int {
        let value = filename
            .replacingOccurrences(of: "context_sub_", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        return Int(value) ?? 0
    }

    private static func readTimestamps(
        wirePath: String,
        limits: ParserLimits
    ) throws -> (startTime: String, endTime: String) {
        guard JSONLAdapterSupport.fileExists(wirePath) else { return ("", "") }
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: wirePath, limits: limits)
        if let failure { throw failure }
        var startTime = ""
        var endTime = ""
        for object in objects {
            guard let timestamp = Phase4AdapterSupport.double(object["timestamp"]) else { continue }
            let iso = Phase4AdapterSupport.isoFromSeconds(timestamp)
            if startTime.isEmpty { startTime = iso }
            endTime = iso
        }
        return (startTime, endTime)
    }

    private static func isConversation(_ object: Phase4AdapterSupport.JSONObject) -> Bool {
        let role = JSONLAdapterSupport.string(object["role"])
        return role == "user" || role == "assistant"
    }

    private static func message(from object: Phase4AdapterSupport.JSONObject) -> NormalizedMessage? {
        guard isConversation(object),
              let role = JSONLAdapterSupport.string(object["role"])
        else {
            return nil
        }
        return NormalizedMessage(
            role: role == "user" ? .user : .assistant,
            content: JSONLAdapterSupport.string(object["content"]) ?? "",
            timestamp: nil,
            toolCalls: nil,
            usage: nil
        )
    }
}

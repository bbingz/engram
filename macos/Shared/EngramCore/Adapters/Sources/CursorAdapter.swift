import Foundation

final class CursorAdapter: SessionAdapter, Sendable {
    let source: SourceName = .cursor
    private let dbPath: String
    private let accessibilityCache = Phase4SQLiteAccessibilityCache()

    init(
        dbPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    ) {
        self.dbPath = dbPath
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.fileExists(dbPath)
    }

    func listSessionLocators() async throws -> [String] {
        do {
            let database = try Phase4SQLiteDatabase(path: dbPath)
            let rows = try database.query(
                "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
            )
            return rows.compactMap { row in
                guard let value = row["value"] ?? nil,
                      let data = Phase4AdapterSupport.jsonObject(from: value),
                      let composerId = JSONLAdapterSupport.string(data["composerId"]),
                      !composerId.isEmpty
                else {
                    return nil
                }
                return "\(dbPath)?composer=\(composerId)"
            }
        } catch {
            return []
        }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            return .failure(.unsupportedVirtualLocator)
        }

        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            guard let composerRow = try database.query(
                "SELECT value FROM cursorDiskKV WHERE key = ?",
                bindings: ["composerData:\(locatorParts.composerId)"]
            ).first,
                let composerValue = composerRow["value"] ?? nil,
                let composerData = Phase4AdapterSupport.jsonObject(from: composerValue)
            else {
                return .failure(.malformedJSON)
            }

            let bubbleResult = try Self.bubbles(
                database: database,
                composerData: composerData,
                composerId: locatorParts.composerId
            )
            let visibleBubbles = bubbleResult.bubbles.compactMap(Self.visibleBubble)
            let userCount = visibleBubbles.filter { $0.role == .user }.count
            let assistantCount = visibleBubbles.filter { $0.role == .assistant }.count
            let createdAt = Phase4AdapterSupport.double(composerData["createdAt"]) ?? 0
            let lastUpdatedAt = Phase4AdapterSupport.double(composerData["lastUpdatedAt"]) ?? createdAt
            let summary = JSONLAdapterSupport.string(
                JSONLAdapterSupport.object(composerData["latestConversationSummary"])?["summary"]
            )
            // Per-session size = this composer's raw JSON payload plus the raw
            // JSON of any separately-stored bubble rows. state.vscdb is shared
            // by every Cursor session, so measuring the whole file (the old
            // behavior) attributed the entire DB size to each session. This
            // matches the TS cursor adapter byte-for-byte for parity.
            let perSessionBytes = Int64(composerValue.utf8.count) + bubbleResult.rawBubbleBytes

            return .success(
                NormalizedSessionInfo(
                    id: JSONLAdapterSupport.string(composerData["composerId"]) ?? locatorParts.composerId,
                    source: .cursor,
                    startTime: Phase4AdapterSupport.isoFromMilliseconds(createdAt),
                    endTime: lastUpdatedAt != createdAt ? Phase4AdapterSupport.isoFromMilliseconds(lastUpdatedAt) : nil,
                    cwd: "",
                    project: nil,
                    model: nil,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: summary.map { String($0.prefix(200)) },
                    filePath: locator,
                    sizeBytes: perSessionBytes,
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
            return .failure(.sqliteUnreadable)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            throw ParserFailure.unsupportedVirtualLocator
        }

        do {
            let database = try Phase4SQLiteDatabase(path: locatorParts.dbPath)
            var composerData: Phase4AdapterSupport.JSONObject = [:]
            if let composerRow = try database.query(
                "SELECT value FROM cursorDiskKV WHERE key = ?",
                bindings: ["composerData:\(locatorParts.composerId)"]
            ).first,
                let composerValue = composerRow["value"] ?? nil,
                let parsed = Phase4AdapterSupport.jsonObject(from: composerValue)
            {
                composerData = parsed
            }
            let bubbleResult = try Self.bubbles(
                database: database,
                composerData: composerData,
                composerId: locatorParts.composerId
            )
            let messages = bubbleResult.bubbles.compactMap { bubble -> NormalizedMessage? in
                guard let visible = Self.visibleBubble(bubble) else { return nil }
                let timestamp = Phase4AdapterSupport.double(
                    JSONLAdapterSupport.object(bubble["timingInfo"])?["clientStartTime"]
                )
                .map { Phase4AdapterSupport.isoFromMilliseconds($0) }
                return NormalizedMessage(
                    role: visible.role,
                    content: visible.content,
                    timestamp: timestamp,
                    toolCalls: nil,
                    usage: nil
                )
            }
            return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
        } catch let failure as ParserFailure {
            throw failure
        } catch {
            throw ParserFailure.sqliteUnreadable
        }
    }

    func isAccessible(locator: String) async -> Bool {
        guard let locatorParts = Self.parseVirtualLocator(locator) else {
            return false
        }
        return await accessibilityCache.contains(
            path: locatorParts.dbPath,
            sql:
            "SELECT 1 FROM cursorDiskKV WHERE key = ? LIMIT 1",
            bindings: ["composerData:\(locatorParts.composerId)"]
        )
    }

    private static func parseVirtualLocator(_ locator: String) -> (dbPath: String, composerId: String)? {
        guard let range = locator.range(of: "?composer=") else { return nil }
        return (
            dbPath: String(locator[..<range.lowerBound]),
            composerId: String(locator[range.upperBound...])
        )
    }

    private struct BubbleLoadResult {
        let bubbles: [Phase4AdapterSupport.JSONObject]
        /// Raw UTF-8 byte total of separately-stored bubble row JSON values
        /// (0 when the conversation is embedded in composerData). Mirrors the
        /// TS cursor adapter so per-session sizeBytes stays in parity.
        let rawBubbleBytes: Int64
    }

    private static func bubbles(
        database: Phase4SQLiteDatabase,
        composerData: Phase4AdapterSupport.JSONObject,
        composerId: String
    ) throws -> BubbleLoadResult {
        if let conversation = JSONLAdapterSupport.array(composerData["conversation"]),
           !conversation.isEmpty
        {
            return BubbleLoadResult(
                bubbles: conversation.compactMap { JSONLAdapterSupport.object($0) },
                rawBubbleBytes: 0
            )
        }

        let rows = try database.query(
            "SELECT value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid ASC",
            bindings: ["bubbleId:\(composerId):%"]
        )
        var bubbles: [Phase4AdapterSupport.JSONObject] = []
        var rawBytes: Int64 = 0
        for row in rows {
            guard let value = row["value"] ?? nil else { continue }
            rawBytes += Int64(value.utf8.count)
            if let object = Phase4AdapterSupport.jsonObject(from: value) {
                bubbles.append(object)
            }
        }
        return BubbleLoadResult(bubbles: bubbles, rawBubbleBytes: rawBytes)
    }

    private static func visibleBubble(
        _ bubble: Phase4AdapterSupport.JSONObject
    ) -> (role: NormalizedMessageRole, content: String)? {
        let type = (bubble["type"] as? NSNumber)?.intValue
        let role: NormalizedMessageRole
        if type == 1 {
            role = .user
        } else if type == 2 {
            role = .assistant
        } else {
            return nil
        }

        let content = JSONLAdapterSupport.string(bubble["text"]) ??
            JSONLAdapterSupport.string(bubble["rawText"]) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (role, content)
    }
}

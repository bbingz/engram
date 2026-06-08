// macos/Engram/Models/Session.swift
import Foundation
import GRDB

// MARK: - Session (maps to 'sessions' table — read-only)
struct Session: FetchableRecord, Decodable, Identifiable {
    let id: String
    let source: String
    let startTime: String
    let endTime: String?
    let cwd: String
    let project: String?
    let model: String?
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let systemMessageCount: Int
    let summary: String?
    let filePath: String
    let sourceLocator: String?
    let sizeBytes: Int
    let indexedAt: String
    let agentRole: String?
    let hiddenAt: String?
    let customName: String?
    let tier: String?
    let toolMessageCount: Int
    let generatedTitle: String?
    let parentSessionId: String?
    let suggestedParentId: String?
    let linkSource: String?
    var lastAccessedAt: String? = nil
    var accessCount: Int = 0
    /// 0–100 engagement/quality score computed at index time. Already stored and
    /// consumed by the MCP path for ranking; decoded into the read model here.
    /// Optional + defaulted so a missing column decodes to nil and the memberwise
    /// init stays source-compatible.
    var qualityScore: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, source, cwd, project, model, summary
        case startTime        = "start_time"
        case endTime          = "end_time"
        case messageCount          = "message_count"
        case userMessageCount      = "user_message_count"
        case assistantMessageCount = "assistant_message_count"
        case systemMessageCount    = "system_message_count"
        case filePath         = "file_path"
        case sourceLocator    = "source_locator"
        case sizeBytes        = "size_bytes"
        case indexedAt        = "indexed_at"
        case agentRole        = "agent_role"
        case hiddenAt         = "hidden_at"
        case customName       = "custom_name"
        case tier
        case toolMessageCount = "tool_message_count"
        case generatedTitle   = "generated_title"
        case parentSessionId  = "parent_session_id"
        case suggestedParentId = "suggested_parent_id"
        case linkSource       = "link_source"
        case lastAccessedAt   = "last_accessed_at"
        case accessCount      = "access_count"
        case qualityScore     = "quality_score"
    }

    /// Prefer filePath; fall back to sourceLocator when filePath is empty.
    var effectiveFilePath: String {
        if filePath.isEmpty, let sl = sourceLocator, !sl.isEmpty { return sl }
        return filePath
    }

    /// Coarse value tier from `qualityScore` for an at-a-glance relevance cue in
    /// search results. Thresholds are measured on the live distribution (n=2578
    /// non-skip; min 0 / max 74 / avg 42; scores cluster in 30–39): <=35 low,
    /// >=60 high — NOT 33/67-of-100, since scores top out near 74. nil → unknown.
    enum ValueBand: String { case high, medium, low, unknown }
    static let valueBandLowMax = 35
    static let valueBandHighMin = 60
    var valueBand: ValueBand {
        guard let score = qualityScore else { return .unknown }
        if score >= Self.valueBandHighMin { return .high }
        if score <= Self.valueBandLowMax { return .low }
        return .medium
    }

    var displayTitle: String {
        if let cn = customName, !cn.isEmpty { return cn }
        if let gt = generatedTitle, !gt.isEmpty { return gt }
        if let s = summary, !s.isEmpty { return s }
        return "Untitled"
    }
    var msgCountLabel: String {
        var parts = ["\(userMessageCount) user", "\(assistantMessageCount) asst"]
        if systemMessageCount > 0 { parts.append("\(systemMessageCount) sys") }
        return parts.joined(separator: " · ")
    }
    var displayDate: String        { String(startTime.prefix(10)) }
    var displayUpdatedDate: String { String((endTime ?? startTime).prefix(10)) }
    var accessSortTime: String     { lastAccessedAt ?? startTime }
    var isSubAgent: Bool           { agentRole != nil }
    var hasParent: Bool { parentSessionId != nil }
    var hasSuggestedParent: Bool { suggestedParentId != nil && parentSessionId == nil }
    var formattedSize: String {
        if sizeBytes < 1024 { return "\(sizeBytes) B" }
        let kb = Double(sizeBytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb.rounded()) }
        return String(format: "%.1f MB", kb / 1024)
    }

    enum SizeCategory { case normal, large, huge }
    var sizeCategory: SizeCategory {
        if sizeBytes >= 100 * 1024 * 1024 { return .huge }
        if sizeBytes >= 10 * 1024 * 1024  { return .large }
        return .normal
    }
}

extension Session: Hashable {
    static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Session {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        startTime = try c.decode(String.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(String.self, forKey: .endTime)
        cwd = try c.decode(String.self, forKey: .cwd)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        userMessageCount = try c.decode(Int.self, forKey: .userMessageCount)
        assistantMessageCount = try c.decode(Int.self, forKey: .assistantMessageCount)
        systemMessageCount = try c.decode(Int.self, forKey: .systemMessageCount)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        filePath = try c.decode(String.self, forKey: .filePath)
        sourceLocator = try c.decodeIfPresent(String.self, forKey: .sourceLocator)
        sizeBytes = try c.decode(Int.self, forKey: .sizeBytes)
        indexedAt = try c.decode(String.self, forKey: .indexedAt)
        agentRole = try c.decodeIfPresent(String.self, forKey: .agentRole)
        hiddenAt = try c.decodeIfPresent(String.self, forKey: .hiddenAt)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        toolMessageCount = try c.decode(Int.self, forKey: .toolMessageCount)
        generatedTitle = try c.decodeIfPresent(String.self, forKey: .generatedTitle)
        parentSessionId = try c.decodeIfPresent(String.self, forKey: .parentSessionId)
        suggestedParentId = try c.decodeIfPresent(String.self, forKey: .suggestedParentId)
        linkSource = try c.decodeIfPresent(String.self, forKey: .linkSource)
        lastAccessedAt = try c.decodeIfPresent(String.self, forKey: .lastAccessedAt)
        accessCount = try c.decodeIfPresent(Int.self, forKey: .accessCount) ?? 0
        qualityScore = try c.decodeIfPresent(Int.self, forKey: .qualityScore)
    }
}

// MARK: - Favorite (managed by Swift app — NOT in Node.js schema)
struct Favorite: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "favorites"
    let sessionId: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case createdAt = "created_at"
    }
}

// MARK: - Tag (managed by Swift app)
struct Tag: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "tags"
    let sessionId: String
    let tag: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case tag
        case createdAt = "created_at"
    }
}

// MARK: - FTS result
struct FtsMatch: FetchableRecord, Decodable {
    let sessionId: String
    let content: String
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case content
    }
}

// MARK: - Timeline entry
struct TimelineEntry: FetchableRecord, Decodable {
    let project: String?
    let sessionCount: Int
    let lastUpdated: String
    enum CodingKeys: String, CodingKey {
        case project
        case sessionCount = "session_count"
        case lastUpdated  = "last_updated"
    }
}

// MARK: - Source count (for stats)
struct SourceCount: FetchableRecord, Decodable {
    let source: String
    let count: Int
}

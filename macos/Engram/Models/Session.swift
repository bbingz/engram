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
    let summary: String?
    let filePath: String
    let sizeBytes: Int
    let indexedAt: String
    let agentRole: String?
    let hiddenAt: String?
    let customName: String?

    enum CodingKeys: String, CodingKey {
        case id, source, cwd, project, model, summary
        case startTime        = "start_time"
        case endTime          = "end_time"
        case messageCount     = "message_count"
        case userMessageCount = "user_message_count"
        case filePath         = "file_path"
        case sizeBytes        = "size_bytes"
        case indexedAt        = "indexed_at"
        case agentRole        = "agent_role"
        case hiddenAt         = "hidden_at"
        case customName       = "custom_name"
    }

    var displayTitle: String {
        if let cn = customName {
            if let s = summary { return "\(cn) | \(s)" }
            return cn
        }
        return summary ?? "Untitled"
    }
    var displayDate: String        { String(startTime.prefix(10)) }
    var displayUpdatedDate: String { String((endTime ?? startTime).prefix(10)) }
    var isSubAgent: Bool           { agentRole != nil }
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

import Foundation
import GRDB

struct GitRepo: FetchableRecord, Decodable, Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let branch: String?
    let dirtyCount: Int
    let untrackedCount: Int
    let unpushedCount: Int
    let lastCommitHash: String?
    let lastCommitMsg: String?
    let lastCommitAt: String?
    let sessionCount: Int
    let probedAt: String?

    enum CodingKeys: String, CodingKey {
        case path, name, branch
        case dirtyCount = "dirty_count"
        case untrackedCount = "untracked_count"
        case unpushedCount = "unpushed_count"
        case lastCommitHash = "last_commit_hash"
        case lastCommitMsg = "last_commit_msg"
        case lastCommitAt = "last_commit_at"
        case sessionCount = "session_count"
        case probedAt = "probed_at"
    }

    // Reuse one formatter instead of allocating a fresh ISO8601DateFormatter
    // per isActive call (the property is hit per-row in list rendering).
    private static let iso8601Formatter = ISO8601DateFormatter()

    var isActive: Bool {
        guard let ts = lastCommitAt else { return false }
        guard let date = Self.iso8601Formatter.date(from: ts) else { return false }
        return date.timeIntervalSinceNow > -86400 // 24h
    }

    var isDirty: Bool { dirtyCount > 0 || untrackedCount > 0 }
}

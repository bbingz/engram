// macos/EngramTests/SessionModelTests.swift
import XCTest
import GRDB
@testable import Engram

final class SessionModelTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    // MARK: - Helper

    /// Build a Session value directly for unit testing (bypassing DB).
    private func makeSession(
        id: String = "test-\(UUID().uuidString)",
        source: String = "claude-code",
        startTime: String = "2026-03-20T10:00:00Z",
        endTime: String? = "2026-03-20T11:00:00Z",
        cwd: String = "/tmp",
        project: String? = "engram",
        model: String? = "sonnet",
        messageCount: Int = 10,
        userMessageCount: Int = 5,
        assistantMessageCount: Int = 4,
        systemMessageCount: Int = 1,
        summary: String? = "A test summary",
        filePath: String = "/tmp/test.jsonl",
        sourceLocator: String? = nil,
        sizeBytes: Int = 50000,
        indexedAt: String = "2026-03-20T12:00:00Z",
        agentRole: String? = nil,
        hiddenAt: String? = nil,
        customName: String? = nil,
        tier: String? = "normal",
        toolMessageCount: Int = 0,
        generatedTitle: String? = nil,
        lastAccessedAt: String? = nil,
        accessCount: Int = 0
    ) -> Session {
        // Decode from a dictionary since Session conforms to Decodable
        let dict: [String: Any?] = [
            "id": id,
            "source": source,
            "start_time": startTime,
            "end_time": endTime,
            "cwd": cwd,
            "project": project,
            "model": model,
            "message_count": messageCount,
            "user_message_count": userMessageCount,
            "assistant_message_count": assistantMessageCount,
            "system_message_count": systemMessageCount,
            "summary": summary,
            "file_path": filePath,
            "source_locator": sourceLocator,
            "size_bytes": sizeBytes,
            "indexed_at": indexedAt,
            "agent_role": agentRole,
            "hidden_at": hiddenAt,
            "custom_name": customName,
            "tier": tier,
            "tool_message_count": toolMessageCount,
            "generated_title": generatedTitle,
            "last_accessed_at": lastAccessedAt,
            "access_count": accessCount,
        ]
        // Filter out nil values for proper JSON encoding
        var cleaned: [String: Any] = [:]
        for (key, value) in dict {
            if let v = value {
                cleaned[key] = v
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: cleaned)
        return try! JSONDecoder().decode(Session.self, from: data)
    }

    // MARK: - displayTitle tests

    /// 1. displayTitle returns customName when set
    func testDisplayTitleCustomName() throws {
        let session = makeSession(summary: "Summary", customName: "My Custom Name", generatedTitle: "Generated")
        XCTAssertEqual(session.displayTitle, "My Custom Name")
    }

    /// 2. displayTitle falls back to generatedTitle when no customName
    func testDisplayTitleGeneratedTitle() throws {
        let session = makeSession(summary: "Summary", customName: nil, generatedTitle: "Generated Title")
        XCTAssertEqual(session.displayTitle, "Generated Title")
    }

    /// 3. displayTitle falls back to summary when no customName or generatedTitle
    func testDisplayTitleSummary() throws {
        let session = makeSession(summary: "A summary", customName: nil, generatedTitle: nil)
        XCTAssertEqual(session.displayTitle, "A summary")
    }

    /// 4. displayTitle returns "Untitled" when nothing is set
    func testDisplayTitleUntitled() throws {
        let session = makeSession(summary: nil, customName: nil, generatedTitle: nil)
        XCTAssertEqual(session.displayTitle, "Untitled")
    }

    /// 5. displayTitle skips empty customName
    func testDisplayTitleSkipsEmptyCustomName() throws {
        let session = makeSession(summary: nil, customName: "", generatedTitle: "Fallback")
        XCTAssertEqual(session.displayTitle, "Fallback")
    }

    // MARK: - effectiveFilePath tests

    /// effectiveFilePath returns filePath when it is non-empty
    func testEffectiveFilePathUsesFilePath() throws {
        let session = makeSession(filePath: "/tmp/test.jsonl", sourceLocator: "/other/path.jsonl")
        XCTAssertEqual(session.effectiveFilePath, "/tmp/test.jsonl")
    }

    /// effectiveFilePath falls back to sourceLocator when filePath is empty
    func testEffectiveFilePathFallsBackToSourceLocator() throws {
        let session = makeSession(filePath: "", sourceLocator: "/Users/bing/.codex/sessions/test.jsonl")
        XCTAssertEqual(session.effectiveFilePath, "/Users/bing/.codex/sessions/test.jsonl")
    }

    /// effectiveFilePath returns empty when both are empty
    func testEffectiveFilePathBothEmpty() throws {
        let session = makeSession(filePath: "", sourceLocator: nil)
        XCTAssertEqual(session.effectiveFilePath, "")
    }

    func testAccessSortTimeFallsBackToStartTime() throws {
        let session = makeSession(
            startTime: "2026-03-20T10:00:00Z",
            lastAccessedAt: nil
        )
        XCTAssertEqual(session.accessSortTime, "2026-03-20T10:00:00Z")
    }

    func testAccessSortTimePrefersLastAccessedAt() throws {
        let session = makeSession(
            startTime: "2026-03-20T10:00:00Z",
            lastAccessedAt: "2026-03-21T12:00:00Z",
            accessCount: 3
        )
        XCTAssertEqual(session.accessSortTime, "2026-03-21T12:00:00Z")
        XCTAssertEqual(session.accessCount, 3)
    }

    func testDecodeDefaultsMissingAccessMetadata() throws {
        let data = """
        {
          "id": "legacy",
          "source": "codex",
          "start_time": "2026-03-20T10:00:00Z",
          "cwd": "/tmp",
          "message_count": 1,
          "user_message_count": 1,
          "assistant_message_count": 0,
          "system_message_count": 0,
          "file_path": "/tmp/legacy.jsonl",
          "size_bytes": 1,
          "indexed_at": "2026-03-20T10:00:00Z",
          "tool_message_count": 0
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(Session.self, from: data)

        XCTAssertNil(session.lastAccessedAt)
        XCTAssertEqual(session.accessCount, 0)
        XCTAssertEqual(session.accessSortTime, "2026-03-20T10:00:00Z")
    }

    // MARK: - formattedSize tests

    /// 6. formattedSize for small bytes
    func testFormattedSizeBytes() throws {
        let session = makeSession(sizeBytes: 512)
        XCTAssertEqual(session.formattedSize, "512 B")
    }

    /// 7. formattedSize for kilobytes
    func testFormattedSizeKB() throws {
        let session = makeSession(sizeBytes: 50 * 1024) // 50 KB
        XCTAssertEqual(session.formattedSize, "50 KB")
    }

    /// 8. formattedSize for megabytes
    func testFormattedSizeMB() throws {
        let session = makeSession(sizeBytes: 5 * 1024 * 1024) // 5 MB
        XCTAssertEqual(session.formattedSize, "5.0 MB")
    }

    // MARK: - sizeCategory tests

    /// 9. sizeCategory thresholds
    func testSizeCategory() throws {
        let normal = makeSession(sizeBytes: 1024) // 1 KB
        XCTAssertEqual(normal.sizeCategory, .normal)

        let large = makeSession(sizeBytes: 10 * 1024 * 1024) // 10 MB
        XCTAssertEqual(large.sizeCategory, .large)

        let huge = makeSession(sizeBytes: 100 * 1024 * 1024) // 100 MB
        XCTAssertEqual(huge.sizeCategory, .huge)

        // Just below large threshold → normal
        let belowLarge = makeSession(sizeBytes: 10 * 1024 * 1024 - 1)
        XCTAssertEqual(belowLarge.sizeCategory, .normal)
    }

    // MARK: - Equatable / Hashable

    /// 10. Equatable is id-based, Hashable works in Set
    func testEquatableAndHashable() throws {
        // Same id → equal, even with different content
        let a = makeSession(id: "same-id", summary: "Summary A", sizeBytes: 100)
        let b = makeSession(id: "same-id", summary: "Summary B", sizeBytes: 999)
        XCTAssertEqual(a, b, "Sessions with same id should be equal")

        // Different id → not equal
        let c = makeSession(id: "different-id", summary: "Summary A", sizeBytes: 100)
        XCTAssertNotEqual(a, c)

        // Hashable: Set deduplicates by id
        var set = Set<Session>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Set should deduplicate sessions with same id")

        set.insert(c)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - M19 favorite flag + toggle presentation

    func testIsFavoriteDefaultsFalseOnDecode() throws {
        let session = makeSession()
        XCTAssertFalse(session.isFavorite)
    }

    func testApplyingFavoriteIdsMarksMatchingSessions() throws {
        let a = makeSession(id: "a")
        let b = makeSession(id: "b")
        let c = makeSession(id: "c")
        let marked = Session.applyingFavoriteIds([a, b, c], favoriteIds: ["a", "c"])
        XCTAssertEqual(marked.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(marked[0].isFavorite)
        XCTAssertFalse(marked[1].isFavorite)
        XCTAssertTrue(marked[2].isFavorite)
    }

    func testFavoriteToggleTargetIsSymmetricNegation() throws {
        var session = makeSession(id: "starred")
        session.isFavorite = true
        XCTAssertFalse(session.favoriteToggleTarget)
        session.isFavorite = false
        XCTAssertTrue(session.favoriteToggleTarget)
    }

    func testFavoriteMenuLabelReflectsAddVersusRemove() throws {
        XCTAssertEqual(Session.favoriteMenuLabel(isFavorite: false), "Add to Favorites")
        XCTAssertEqual(Session.favoriteMenuLabel(isFavorite: true), "Remove from Favorites")
        XCTAssertEqual(Session.favoriteAccessibilityLabel(isFavorite: false), "Add to favorites")
        XCTAssertEqual(Session.favoriteAccessibilityLabel(isFavorite: true), "Remove from favorites")
    }
}

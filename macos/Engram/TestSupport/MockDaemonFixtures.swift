#if DEBUG
// macos/Engram/TestSupport/MockDaemonFixtures.swift
import Foundation

/// Provides fixture JSON responses matching the Decodable structs in DaemonClient.swift.
/// Used by MockURLProtocol to simulate daemon API responses in debug/preview builds.
enum MockDaemonFixtures {
    static func response(for path: String) -> (HTTPURLResponse, Data?) {
        let url = URL(string: "http://localhost:9999\(path)")!
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
        let json: String

        switch path {
        case _ where path.hasSuffix("/api/live"):
            // Matches LiveSessionsResponse { sessions: [LiveSessionInfo], count: Int }
            // LiveSessionInfo fields: source (String), sessionId (String?), project (String?),
            //   title (String?), cwd (String?), filePath (String), startedAt (String?),
            //   model (String?), currentActivity (String?), lastModifiedAt (String),
            //   activityLevel (String?)
            json = """
            {
                "sessions": [
                    {
                        "source": "claude-code",
                        "sessionId": "live-1",
                        "project": "test-project",
                        "filePath": "/tmp/live-1.jsonl",
                        "startedAt": "2026-01-15T09:00:00Z",
                        "lastModifiedAt": "2026-01-15T09:30:00Z",
                        "activityLevel": "active"
                    },
                    {
                        "source": "cursor",
                        "sessionId": "live-2",
                        "project": "other-project",
                        "filePath": "/tmp/live-2.jsonl",
                        "startedAt": "2026-01-15T09:30:00Z",
                        "lastModifiedAt": "2026-01-15T09:45:00Z",
                        "activityLevel": "idle"
                    }
                ],
                "count": 2
            }
            """

        case _ where path.hasSuffix("/api/memory"):
            // Matches [MemoryFile] array
            // MemoryFile fields: name (String), project (String), path (String),
            //   sizeBytes (Int), preview (String)
            json = """
            [
                {"name": "user_role", "project": "global", "path": "/tmp/memory/user_role.md", "sizeBytes": 128, "preview": "Developer"},
                {"name": "project_context", "project": "engram", "path": "/tmp/memory/project.md", "sizeBytes": 256, "preview": "Engram app"},
                {"name": "preference", "project": "global", "path": "/tmp/memory/pref.md", "sizeBytes": 64, "preview": "Dark mode"}
            ]
            """

        case _ where path.hasSuffix("/api/skills"):
            // Matches [SkillInfo] array
            // SkillInfo fields: name (String), description (String), path (String), scope (String)
            json = """
            [
                {"name": "commit", "description": "Create a git commit", "path": "/tmp/skills/commit.md", "scope": "global"},
                {"name": "review-pr", "description": "Review a pull request", "path": "/tmp/skills/review.md", "scope": "project"}
            ]
            """

        case _ where path.hasSuffix("/api/hooks"):
            // Matches [HookInfo] array
            // HookInfo fields: event (String), command (String), scope (String)
            json = """
            [
                {"event": "PreToolUse", "command": "echo hook1", "scope": "project"},
                {"event": "PostToolUse", "command": "echo hook2", "scope": "global"}
            ]
            """

        default:
            json = "{}"
        }

        return (response, json.data(using: .utf8))
    }
}
#endif

import Foundation

enum MCPLiveSessionScanner {
    static func scan(home: String, now: Date = Date()) -> OrderedJSONValue {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let roots: [(source: String, url: URL, extensions: Set<String>)] = [
            ("codex", homeURL.appendingPathComponent(".codex/sessions", isDirectory: true), ["jsonl"]),
            ("claude-code", homeURL.appendingPathComponent(".claude/projects", isDirectory: true), ["jsonl"]),
            ("gemini-cli", homeURL.appendingPathComponent(".gemini/tmp", isDirectory: true), ["json"]),
            ("antigravity", homeURL.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true), ["json", "jsonl"]),
            ("antigravity", homeURL.appendingPathComponent(".gemini/antigravity", isDirectory: true), ["json", "jsonl"]),
            ("opencode", homeURL.appendingPathComponent(".local/share/opencode", isDirectory: true), ["db"]),
        ]
        let recentWindow: TimeInterval = 24 * 60 * 60
        var sessions: [OrderedJSONValue] = []
        var seen = Set<String>()

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.url.path) else { continue }
            let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            guard let enumerator else { continue }
            for case let file as URL in enumerator {
                guard sessions.count < 100 else { break }
                guard root.extensions.contains(file.pathExtension.lowercased()) else { continue }
                guard seen.insert(file.path).inserted else { continue }
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate
                else { continue }
                let age = now.timeIntervalSince(modifiedAt)
                guard age >= 0, age <= recentWindow else { continue }
                let level = age <= 120 ? "active" : (age <= 900 ? "idle" : "recent")
                let text = readPrefix(file)
                sessions.append(.object([
                    ("source", .string(root.source)),
                    ("sessionId", nullable(firstStringValue(keys: ["id", "session_id", "sessionId"], in: text))),
                    ("project", nullable(firstStringValue(keys: ["project"], in: text))),
                    ("title", nullable(firstStringValue(keys: ["generated_title", "title", "summary"], in: text))),
                    ("cwd", nullable(firstStringValue(keys: ["cwd", "workspace"], in: text))),
                    ("filePath", .string(file.path)),
                    ("lastModifiedAt", .string(isoString(modifiedAt))),
                    ("activityLevel", .string(level)),
                ]))
            }
        }
        return .object([
            ("sessions", .array(sessions)),
            ("count", .int(sessions.count)),
        ])
    }

    private static func readPrefix(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return "" }
        return String(data: Data(data.prefix(64 * 1024)), encoding: .utf8) ?? ""
    }

    private static func nullable(_ value: String?) -> OrderedJSONValue {
        guard let value else { return .null }
        return .string(value)
    }

    private static func firstStringValue(keys: [String], in text: String) -> String? {
        for key in keys {
            let pattern = #""\#(NSRegularExpression.escapedPattern(for: key))"\s*:\s*"([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[valueRange])
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

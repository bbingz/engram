import Foundation

enum MCPFileTools {
    static func projectReview(
        oldPath: String,
        newPath: String,
        maxItems: Int
    ) -> OrderedJSONValue {
        let expandedOldPath = expandHome(oldPath)
        let expandedNewPath = expandHome(newPath)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let roots = sourceRoots(home: home)
        let ccRoot = roots.first { $0.id == "claude-code" }?.path
        let ownCCDir = encodeCC(expandedNewPath)

        var own = Set<String>()
        var other = Set<String>()

        for root in roots {
            let hits = findReferencingFiles(root: root.path, needle: expandedOldPath)
            for hit in hits {
                var isOther = false
                if let ccRoot, hit.hasPrefix(ccRoot + "/") {
                    let relative = String(hit.dropFirst(ccRoot.count + 1))
                    let firstSegment = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                    if firstSegment != ownCCDir {
                        isOther = true
                    }
                }
                if isOther {
                    other.insert(hit)
                } else {
                    own.insert(hit)
                }
            }
        }

        let sortedOwn = own.sorted()
        let sortedOther = other.sorted()
        let cap = max(maxItems, 1)

        var entries: [(String, OrderedJSONValue)] = [
            ("own", .array(sortedOwn.prefix(cap).map(OrderedJSONValue.string))),
            ("other", .array(sortedOther.prefix(cap).map(OrderedJSONValue.string))),
        ]

        let ownOverflow = max(0, sortedOwn.count - cap)
        let otherOverflow = max(0, sortedOther.count - cap)
        if ownOverflow > 0 || otherOverflow > 0 {
            entries.append((
                "truncated",
                .object([
                    ("own", .int(ownOverflow)),
                    ("other", .int(otherOverflow)),
                ])
            ))
        }

        return .object(entries)
    }
}

private struct MCPSourceRoot {
    let id: String
    let path: String
}

func trimTrailingSlash(_ path: String) -> String {
    guard path.count > 1 else { return path }
    return path.hasSuffix("/") ? String(path.dropLast()) : path
}

private func expandHome(_ path: String) -> String {
    if path == "~" {
        return NSHomeDirectory()
    }
    if path.hasPrefix("~/") {
        return NSHomeDirectory() + "/" + path.dropFirst(2)
    }
    return path
}

private func encodeCC(_ path: String) -> String {
    let units = path.utf16.map { u -> UInt16 in
        let isAlnum = (u >= 48 && u <= 57) // 0-9
            || (u >= 65 && u <= 90) // A-Z
            || (u >= 97 && u <= 122) // a-z
        return isAlnum ? u : 45 // '-'
    }
    return String(utf16CodeUnits: units, count: units.count)
}

private func sourceRoots(home: String) -> [MCPSourceRoot] {
    [
        MCPSourceRoot(id: "claude-code", path: "\(home)/.claude/projects"),
        MCPSourceRoot(id: "codex", path: "\(home)/.codex/sessions"),
        MCPSourceRoot(id: "gemini-cli", path: "\(home)/.gemini/tmp"),
        MCPSourceRoot(id: "iflow", path: "\(home)/.iflow/projects"),
        MCPSourceRoot(id: "qoder", path: "\(home)/.qoder/projects"),
        MCPSourceRoot(id: "commandcode", path: "\(home)/.commandcode/projects"),
        MCPSourceRoot(id: "opencode", path: "\(home)/.local/share/opencode"),
        MCPSourceRoot(id: "antigravity", path: "\(home)/.gemini/antigravity-cli/brain"),
        MCPSourceRoot(id: "antigravity-legacy", path: "\(home)/.gemini/antigravity"),
        MCPSourceRoot(id: "copilot", path: "\(home)/.copilot"),
    ]
}

private func findReferencingFiles(root: String, needle: String) -> [String] {
    guard !needle.isEmpty, FileManager.default.fileExists(atPath: root) else { return [] }
    let allowedExtensions = Set(["json", "jsonl"])
    guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }

    var hits: [String] = []
    for case let fileURL as URL in enumerator {
        guard allowedExtensions.contains(fileURL.pathExtension) else { continue }
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { continue }
        if text.contains(needle) {
            hits.append(fileURL.path)
        }
    }
    return hits.sorted()
}

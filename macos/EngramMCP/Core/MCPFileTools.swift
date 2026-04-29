import Foundation

enum MCPFileTools {
    static func lintConfig(cwd: String) -> OrderedJSONValue {
        let issues = lintIssues(cwd: cwd)
        let score = max(
            0,
            100 - issues.reduce(0) { partial, issue in
                partial + severityPenalty(issue.severity)
            }
        )

        return .object([
            ("issues", .array(issues.map(issueJSON))),
            ("score", .int(score)),
        ])
    }

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

private struct MCPLintIssue {
    let file: String
    let line: Int
    let severity: String
    let message: String
    let suggestion: String?
}

private struct MCPSourceRoot {
    let id: String
    let path: String
}

private func lintIssues(cwd: String) -> [MCPLintIssue] {
    let configFiles = findConfigFiles(cwd: cwd)
    let scripts = readPackageScripts(cwd: cwd)
    var issues: [MCPLintIssue] = []

    for configFile in configFiles {
        guard let content = try? String(contentsOfFile: configFile, encoding: .utf8) else { continue }
        var inCodeBlock = false
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { continue }

            for ref in extractBacktickRefs(line) {
                if looksLikeFilePath(ref) {
                    let resolvedRoot = URL(fileURLWithPath: cwd).standardizedFileURL.path
                    let fullPath = URL(fileURLWithPath: ref, relativeTo: URL(fileURLWithPath: resolvedRoot)).standardizedFileURL.path
                    guard fullPath == resolvedRoot || fullPath.hasPrefix(resolvedRoot + "/") else { continue }
                    if !FileManager.default.fileExists(atPath: fullPath) {
                        issues.append(
                            MCPLintIssue(
                                file: configFile,
                                line: index + 1,
                                severity: "error",
                                message: "Referenced file `\(ref)` does not exist",
                                suggestion: findSimilarFile(cwd: cwd, ref: ref).map { "Did you mean `\($0)`?" }
                            )
                        )
                    }
                }

                if let script = looksLikeNPMScript(ref), scripts != nil, scripts?[script] == nil {
                    issues.append(
                        MCPLintIssue(
                            file: configFile,
                            line: index + 1,
                            severity: "warning",
                            message: "npm script `\(script)` not found in package.json",
                            suggestion: nil
                        )
                    )
                }
            }
        }
    }

    return issues
}

private func issueJSON(_ issue: MCPLintIssue) -> OrderedJSONValue {
    var entries: [(String, OrderedJSONValue)] = [
        ("file", .string(issue.file)),
        ("line", .int(issue.line)),
        ("severity", .string(issue.severity)),
        ("message", .string(issue.message)),
    ]
    if let suggestion = issue.suggestion {
        entries.append(("suggestion", .string(suggestion)))
    }
    return .object(entries)
}

private func severityPenalty(_ severity: String) -> Int {
    switch severity {
    case "error":
        return 10
    case "warning":
        return 3
    default:
        return 1
    }
}

private func extractBacktickRefs(_ line: String) -> [String] {
    let pattern = try? NSRegularExpression(pattern: "`([^`]+)`")
    let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
    return pattern?.matches(in: line, range: nsRange).compactMap { match in
        guard let range = Range(match.range(at: 1), in: line) else { return nil }
        let value = line[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    } ?? []
}

private func looksLikeFilePath(_ ref: String) -> Bool {
    if ref.hasPrefix("http://") || ref.hasPrefix("https://") { return false }
    if ref.hasPrefix("@"), ref.contains("/"), !ref.contains(" ") { return false }
    if ref.contains(" "), !ref.contains("/") { return false }
    if ref.hasSuffix("/") { return true }

    let ext = URL(fileURLWithPath: ref).pathExtension
    if !ext.isEmpty, ext.count <= 8 { return true }
    if ref.contains("/"), !ref.hasPrefix("-"), !ref.contains(" ") { return true }
    return false
}

private func looksLikeNPMScript(_ ref: String) -> String? {
    if let match = ref.firstMatch(of: /^npm\s+run\s+(\S+)/) {
        return String(match.1)
    }
    if let match = ref.firstMatch(of: /^npm\s+(test|start|stop|restart)(?:\s|$)/) {
        return String(match.1)
    }
    return nil
}

private func findConfigFiles(cwd: String) -> [String] {
    [
        "\(cwd)/CLAUDE.md",
        "\(cwd)/.claude/CLAUDE.md",
        "\(cwd)/AGENTS.md",
        "\(cwd)/.cursorrules",
        "\(cwd)/.github/copilot-instructions.md",
    ].filter { FileManager.default.fileExists(atPath: $0) }
}

private func readPackageScripts(cwd: String) -> [String: String]? {
    let packagePath = "\(cwd)/package.json"
    guard
        let data = FileManager.default.contents(atPath: packagePath),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let scripts = root["scripts"] as? [String: String]
    else {
        return nil
    }
    return scripts
}

private func findSimilarFile(cwd: String, ref: String) -> String? {
    let parent = URL(fileURLWithPath: ref).deletingLastPathComponent().path
    let name = URL(fileURLWithPath: ref).lastPathComponent
    let directory = URL(fileURLWithPath: cwd).appendingPathComponent(parent).path
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }

    let lowercase = name.lowercased()
    if let match = entries.first(where: { $0.lowercased() == lowercase }) {
        let normalizedParent = parent == "/" ? "" : parent
        return normalizedParent.isEmpty ? match : "\(normalizedParent)/\(match)"
    }

    let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    let ext = "." + URL(fileURLWithPath: name).pathExtension
    let swaps: [String: [String]] = [
        ".ts": [".tsx", ".js", ".mjs"],
        ".tsx": [".ts", ".jsx"],
        ".js": [".ts", ".mjs", ".cjs"],
        ".jsx": [".tsx", ".js"],
        ".swift": [".m", ".mm"],
    ]
    for alt in swaps[ext] ?? [] {
        let altName = base + alt
        if entries.contains(altName) {
            let normalizedParent = parent == "/" ? "" : parent
            return normalizedParent.isEmpty ? altName : "\(normalizedParent)/\(altName)"
        }
    }
    return nil
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
    path.replacingOccurrences(of: "/", with: "-")
}

private func sourceRoots(home: String) -> [MCPSourceRoot] {
    [
        MCPSourceRoot(id: "claude-code", path: "\(home)/.claude/projects"),
        MCPSourceRoot(id: "codex", path: "\(home)/.codex/sessions"),
        MCPSourceRoot(id: "gemini-cli", path: "\(home)/.gemini/tmp"),
        MCPSourceRoot(id: "iflow", path: "\(home)/.iflow/projects"),
        MCPSourceRoot(id: "pi", path: "\(home)/.pi/agent/sessions"),
        MCPSourceRoot(id: "opencode", path: "\(home)/.local/share/opencode"),
        MCPSourceRoot(id: "antigravity", path: "\(home)/.antigravity"),
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

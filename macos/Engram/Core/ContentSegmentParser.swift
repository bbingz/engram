// macos/Engram/Core/ContentSegmentParser.swift
import Foundation

enum ContentSegment: Identifiable {
    case text(String)
    case codeBlock(language: String, code: String)
    case heading(level: Int, text: String)
    case bulletList(items: [String])
    case numberedList(items: [String])
    case taskList(items: [(done: Bool, text: String)])
    case table(headers: [String], rows: [[String]])
    case horizontalRule

    var id: String {
        switch self {
        case .text(let s):           return "t:\(s.hashValue)"
        case .codeBlock(_, let c):   return "c:\(c.hashValue)"
        case .heading(let l, let t): return "h\(l):\(t.hashValue)"
        case .bulletList(let items): return "bl:\(items.count):\(items.first?.hashValue ?? 0)"
        case .numberedList(let items): return "nl:\(items.count):\(items.first?.hashValue ?? 0)"
        case .taskList(let items):   return "tl:\(items.count):\(items.first?.text.hashValue ?? 0)"
        case .table(let h, _):      return "tb:\(h.joined().hashValue)"
        case .horizontalRule:        return "hr"
        }
    }
}

struct ContentSegmentParser {

    static func parse(_ content: String) -> [ContentSegment] {
        let lines = content.components(separatedBy: "\n")
        var segments: [ContentSegment] = []
        var textBuf: [String] = []
        var codeBuf: [String] = []
        var codeLang = ""
        var inCode = false
        var taskBuf: [(done: Bool, text: String)] = []
        var bulletBuf: [String] = []
        var numberedBuf: [String] = []
        var tableBuf: (headers: [String], rows: [[String]])? = nil

        func flushText() {
            guard !textBuf.isEmpty else { return }
            let joined = textBuf.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(joined))
            }
            textBuf.removeAll()
        }

        func flushTasks() {
            guard !taskBuf.isEmpty else { return }
            segments.append(.taskList(items: taskBuf))
            taskBuf.removeAll()
        }

        func flushBullets() {
            guard !bulletBuf.isEmpty else { return }
            segments.append(.bulletList(items: bulletBuf))
            bulletBuf.removeAll()
        }

        func flushNumbered() {
            guard !numberedBuf.isEmpty else { return }
            segments.append(.numberedList(items: numberedBuf))
            numberedBuf.removeAll()
        }

        func flushTable() {
            guard let t = tableBuf, !t.headers.isEmpty else { return }
            segments.append(.table(headers: t.headers, rows: t.rows))
            tableBuf = nil
        }

        func flushAllLists() {
            flushTasks()
            flushBullets()
            flushNumbered()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block fences
            if trimmed.hasPrefix("```") {
                if inCode {
                    let code = codeBuf.joined(separator: "\n")
                    segments.append(.codeBlock(language: codeLang, code: code))
                    codeBuf.removeAll()
                    codeLang = ""
                    inCode = false
                } else {
                    flushAllLists()
                    flushTable()
                    flushText()
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }

            if inCode {
                codeBuf.append(line)
                continue
            }

            // Horizontal rule: ---, ***, ___
            if isHorizontalRule(trimmed) {
                flushAllLists()
                flushTable()
                flushText()
                segments.append(.horizontalRule)
                continue
            }

            // Heading: # text, ## text, etc.
            if let (level, headingText) = parseHeading(trimmed) {
                flushAllLists()
                flushTable()
                flushText()
                segments.append(.heading(level: level, text: headingText))
                continue
            }

            // Task list items: - [ ] or - [x]
            if let taskMatch = parseTaskItem(trimmed) {
                flushBullets()
                flushNumbered()
                flushTable()
                flushText()
                taskBuf.append(taskMatch)
                continue
            } else if !taskBuf.isEmpty {
                flushTasks()
            }

            // Bullet list: - item or * item (but not * * * or ---)
            if let bulletText = parseBulletItem(trimmed) {
                flushNumbered()
                flushTable()
                flushText()
                bulletBuf.append(bulletText)
                continue
            } else if !bulletBuf.isEmpty {
                flushBullets()
            }

            // Numbered list: 1. item, 2. item
            if let numberedText = parseNumberedItem(trimmed) {
                flushBullets()
                flushTable()
                flushText()
                numberedBuf.append(numberedText)
                continue
            } else if !numberedBuf.isEmpty {
                flushNumbered()
            }

            // Pipe table detection
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                let cells = parsePipeRow(trimmed)
                if cells.count >= 2 {
                    if tableBuf == nil {
                        flushText()
                        tableBuf = (headers: cells, rows: [])
                        continue
                    } else if isSeparatorRow(trimmed) {
                        continue
                    } else {
                        tableBuf?.rows.append(cells)
                        continue
                    }
                }
            }
            if tableBuf != nil {
                flushTable()
            }

            // Plain text
            textBuf.append(line)
        }

        // Flush remaining buffers
        if inCode {
            textBuf.append("```\(codeLang)")
            textBuf.append(contentsOf: codeBuf)
        }
        flushAllLists()
        flushTable()
        flushText()

        return segments
    }

    // MARK: - Helpers

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 && line.count > level else { return nil }
        let afterHashes = line[line.index(line.startIndex, offsetBy: level)...]
        guard afterHashes.hasPrefix(" ") else { return nil }
        let text = String(afterHashes).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level: level, text: text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        if stripped.count < 3 { return false }
        if stripped.allSatisfy({ $0 == "-" }) { return true }
        if stripped.allSatisfy({ $0 == "*" }) { return true }
        if stripped.allSatisfy({ $0 == "_" }) { return true }
        return false
    }

    private static func parseTaskItem(_ line: String) -> (done: Bool, text: String)? {
        let patterns: [(prefix: String, done: Bool)] = [
            ("- [x] ", true), ("- [X] ", true), ("- [ ] ", false),
            ("* [x] ", true), ("* [X] ", true), ("* [ ] ", false),
        ]
        for p in patterns {
            if line.hasPrefix(p.prefix) {
                let text = String(line.dropFirst(p.prefix.count))
                return (done: p.done, text: text)
            }
        }
        return nil
    }

    private static func parseBulletItem(_ line: String) -> String? {
        // Must start with "- " or "* " but NOT be a task item or horizontal rule
        for prefix in ["- ", "* "] {
            if line.hasPrefix(prefix) {
                let rest = String(line.dropFirst(prefix.count))
                // Exclude task items (already handled above)
                if rest.hasPrefix("[") { return nil }
                return rest
            }
        }
        return nil
    }

    private static func parseNumberedItem(_ line: String) -> String? {
        // Match: 1. text, 2. text, 10. text, etc.
        guard let dotIdx = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dotIdx]
        guard !prefix.isEmpty && prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line[line.index(after: dotIdx)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        let text = String(afterDot).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func parsePipeRow(_ line: String) -> [String] {
        let inner = line.trimmingCharacters(in: .whitespaces)
            .dropFirst()
            .dropLast()
        return String(inner)
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let inner = line.trimmingCharacters(in: .whitespaces)
            .dropFirst().dropLast()
        let cells = String(inner).components(separatedBy: "|")
        return cells.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return t.allSatisfy { $0 == "-" || $0 == ":" } && t.count >= 1
        }
    }
}

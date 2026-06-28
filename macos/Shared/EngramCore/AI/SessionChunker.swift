import Foundation

public struct TextChunk: Equatable, Sendable {
    public let index: Int
    public let text: String
    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

/// Message-boundary-first chunking for embedding (port of `src/core/chunker.ts`).
/// Accumulates visible messages into ~`maxChars` windows; an oversized single
/// message is split with a sliding window. System messages are skipped.
public enum SessionChunker {
    public static func chunk(
        messages: [(role: String, content: String)],
        maxChars: Int = 800,
        overlap: Int = 200
    ) -> [TextChunk] {
        var chunks: [TextChunk] = []
        var index = 0
        var buffer = ""

        func nonEmpty(_ s: String) -> Bool {
            !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(TextChunk(index: index, text: trimmed))
                index += 1
            }
            buffer = ""
        }

        for message in messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty || message.role == "system" { continue }
            let line = "[\(message.role)] \(content)"

            if line.count > maxChars {
                if nonEmpty(buffer) { flush() }
                for sub in slidingWindow(line, windowSize: maxChars, overlap: overlap) {
                    chunks.append(TextChunk(index: index, text: sub))
                    index += 1
                }
                continue
            }

            if buffer.count + line.count + 1 > maxChars, nonEmpty(buffer) {
                flush()
            }
            buffer += buffer.isEmpty ? line : "\n" + line
        }
        flush()
        return chunks
    }

    private static func slidingWindow(_ text: String, windowSize: Int, overlap: Int) -> [String] {
        let chars = Array(text)
        guard windowSize > overlap, !chars.isEmpty else { return [text] }
        let step = windowSize - overlap
        var results: [String] = []
        var i = 0
        while i < chars.count {
            let end = min(i + windowSize, chars.count)
            results.append(String(chars[i..<end]))
            if end >= chars.count { break }
            i += step
        }
        return results
    }
}

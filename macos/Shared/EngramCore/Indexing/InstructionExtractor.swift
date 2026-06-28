import Foundation

/// Distills the human's distinct, substantive instructions from a session's user
/// turns at index time. The result drives both the "human-driven" default filter
/// (`instruction_count`) and the instruction-first "What you asked" display
/// (`instruction_summary`). Deterministic, no LLM. Co-located with `SessionTier`
/// and reuses its probe stoplist.
public enum InstructionExtractor {
    /// Upper bound on the stored distinct-instruction set. A session with more than
    /// this many distinct asks already satisfies any `instruction_count >= N`
    /// visibility gate, so the cap needs no special predicate handling.
    public static let maxInstructions = 16

    /// Micro-acknowledgements / continuations that are not substantive instructions.
    /// EN + ZH. The list errs toward VISIBLE for other languages: an unknown short
    /// non-Latin phrase passes the script-aware short-token gate (rule 4).
    static let microAcks: Set<String> = [
        "ok", "okay", "yes", "yep", "yup", "no", "nope", "y", "n", "k",
        "continue", "go", "go on", "go ahead", "proceed", "sure", "thanks",
        "thank you", "thx", "done", "next", "got it",
        "继续", "好", "好的", "嗯", "行", "可以", "对", "是",
        "谢谢", "多谢", "明白", "知道了", "收到", "好滴",
    ]

    /// Punctuation that separates polite-ack segments (EN + CJK).
    private static let ackSeparators: Set<Character> = [",", "，", "、", ";", "；", "。", ".", "!", "！", "~"]

    /// Polycli health/launch probe first lines (normalized).
    static let polycliProbes: Set<String> = [
        "polycli_health_ok",
    ]

    /// Returns the instruction text to store (verbatim, capped at 200 chars) when
    /// `content` is a distinct, substantive human instruction not already seen in
    /// this session; `nil` when it is a slash/local command, a tool-result
    /// envelope, a probe/ack, a short ASCII-only token, or a duplicate.
    ///
    /// `seen` accumulates normalized dedup keys across the session so that repeated
    /// asks ("continue" ×5) or a re-sent prompt count once.
    public static func distinctInstruction(from content: String, seen: inout Set<String>) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstLine = (trimmed.split(separator: "\n").first.map(String.init) ?? trimmed)
            .trimmingCharacters(in: .whitespaces)

        // Rule 1: slash / local-command envelopes (Claude Code slash commands).
        if firstLine.hasPrefix("/")
            || trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("<command-message>")
            || trimmed.hasPrefix("<local-command") {
            return nil
        }

        // Rule 2: tool-result envelopes (belt-and-suspenders beyond the upstream
        // role == .tool exclusion in SwiftIndexer.streamStats).
        if trimmed.hasPrefix("<tool_use_result") || trimmed.hasPrefix("<tool_result") {
            return nil
        }

        let normalizedFirst = collapseWhitespace(firstLine.lowercased())

        // Rule 3: probe / ack stoplist (shares SessionTier.probeFirstLines).
        if SessionTier.probeFirstLines.contains(normalizedFirst)
            || microAcks.contains(normalizedFirst)
            || polycliProbes.contains(normalizedFirst)
            || normalizedFirst.hasPrefix("no tools.") {
            return nil
        }

        // Rule 3b: compound polite ack — every punctuation/whitespace-separated
        // segment is itself an ack (e.g. "好的，谢谢" / "ok, thanks").
        let ackSegments = normalizedFirst
            .split { ackSeparators.contains($0) || $0.isWhitespace }
            .map(String.init)
        if ackSegments.count >= 2, ackSegments.allSatisfy({ microAcks.contains($0) }) {
            return nil
        }

        // Rule 4: short ASCII-only token. Script-aware — a short non-Latin ask like
        // "改成深色模式" contains CJK scalars and is KEPT; only pure short Latin
        // tokens like "y" / "k" are rejected.
        if firstLine.count < 8,
           !firstLine.contains(where: { $0.isWhitespace }),
           !containsNonLatin(firstLine) {
            return nil
        }

        // Rule 5: dedup on a normalized full-content key.
        let key = String(collapseWhitespace(trimmed.lowercased()).prefix(200))
        guard !seen.contains(key) else { return nil }
        seen.insert(key)

        return String(trimmed.prefix(200))
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// True when the string contains any non-Latin scalar (CJK/Hangul/Kana/… —
    /// East-Asian block start 0x2E80 and above).
    private static func containsNonLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value > 0x2E80 }
    }
}

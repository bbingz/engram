// macos/Engram/Core/SyntaxHighlighter.swift
import Foundation
import AppKit

// MARK: - Token Rule

private struct TokenRule {
    let pattern: NSRegularExpression
    let color: NSColor
    let captureGroup: Int
}

// MARK: - Cached Result (reference type for NSCache)

private class CachedHighlight {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

// MARK: - SyntaxHighlighter

struct SyntaxHighlighter {

    // MARK: - Colors

    private static let purple = NSColor(red: 0.68, green: 0.32, blue: 0.87, alpha: 1)
    private static let green  = NSColor(red: 0.26, green: 0.71, blue: 0.35, alpha: 1)
    private static let gray   = NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1)
    private static let orange = NSColor(red: 0.85, green: 0.55, blue: 0.20, alpha: 1)
    private static let blue   = NSColor(red: 0.25, green: 0.50, blue: 0.90, alpha: 1)
    private static let yellow = NSColor(red: 0.80, green: 0.72, blue: 0.25, alpha: 1)

    // MARK: - Cache

    private static let cache = NSCache<NSString, CachedHighlight>()

    // MARK: - Entry Point

    /// Highlight `code` using rules for `language`. Returns plain AttributedString for unknown languages or large blocks.
    static func highlight(_ code: String, language: String) -> AttributedString {
        guard !language.isEmpty else { return AttributedString(code) }

        // Skip very large blocks
        let lines = code.components(separatedBy: "\n")
        guard lines.count <= 200 else { return AttributedString(code) }

        // Cache key
        let cacheKey = NSString(string: "\(language):\(code.utf8.count):\(code.prefix(100))")
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }

        let rules = tokenRules(for: language.lowercased())
        guard !rules.isEmpty else {
            let plain = AttributedString(code)
            cache.setObject(CachedHighlight(plain), forKey: cacheKey)
            return plain
        }

        let result = applyRules(rules, to: code)
        cache.setObject(CachedHighlight(result), forKey: cacheKey)
        return result
    }

    // MARK: - Rule Application

    private static func applyRules(_ rules: [TokenRule], to code: String) -> AttributedString {
        // Build NSMutableAttributedString, then convert to AttributedString
        let nsAttr = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: (code as NSString).length)

        // Apply rules in order — later rules can override earlier ones
        for rule in rules {
            rule.pattern.enumerateMatches(in: code, range: fullRange) { match, _, _ in
                guard let match = match else { return }
                let range = match.range(at: rule.captureGroup)
                guard range.location != NSNotFound else { return }
                nsAttr.addAttribute(.foregroundColor, value: rule.color, range: range)
            }
        }

        // Convert to AttributedString for SwiftUI
        // Apply monospaced font as base, then preserve color attributes
        let result = (try? AttributedString(nsAttr, including: \.appKit)) ?? AttributedString(code)
        return result
    }

    // MARK: - Language Rules

    private static func tokenRules(for language: String) -> [TokenRule] {
        switch language {
        case "swift":
            return swiftRules
        case "typescript", "ts", "javascript", "js", "tsx", "jsx":
            return typescriptRules
        case "python", "py":
            return pythonRules
        case "bash", "sh", "shell", "zsh":
            return bashRules
        case "json":
            return jsonRules
        default:
            return []
        }
    }

    // MARK: - Swift Rules

    private static let swiftRules: [TokenRule] = makeRules([
        // Comments
        (#"(//[^\n]*)"#, gray, 1),
        (#"(/\*[\s\S]*?\*/)"#, gray, 1),
        // Strings
        (#"("(?:[^"\\]|\\.)*")"#, green, 1),
        // Numbers
        (#"\b(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, orange, 1),
        // Keywords
        (#"\b(func|var|let|if|else|guard|return|class|struct|enum|protocol|extension|import|for|while|in|switch|case|default|break|continue|throw|throws|try|catch|self|super|nil|true|false|private|public|internal|fileprivate|open|static|final|override|lazy|weak|unowned|init|deinit|where|some|any|actor|async|await|mutating|inout)\b"#, purple, 1),
        // Types (capitalized identifiers)
        (#"\b([A-Z][A-Za-z0-9_]*)\b"#, blue, 1),
        // Function calls
        (#"\b([a-z][A-Za-z0-9_]*)\s*\("#, yellow, 1),
    ])

    // MARK: - TypeScript/JavaScript Rules

    private static let typescriptRules: [TokenRule] = makeRules([
        // Comments
        (#"(//[^\n]*)"#, gray, 1),
        (#"(/\*[\s\S]*?\*/)"#, gray, 1),
        // Strings (single, double, template)
        (#"('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`(?:[^`\\]|\\.)*`)"#, green, 1),
        // Numbers
        (#"\b(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, orange, 1),
        // Keywords
        (#"\b(function|const|let|var|if|else|return|class|interface|type|enum|import|export|from|for|while|in|of|switch|case|default|break|continue|throw|try|catch|finally|new|this|super|null|undefined|true|false|async|await|static|extends|implements|public|private|protected|readonly|abstract|as|typeof|instanceof|void|never|any|unknown|keyof)\b"#, purple, 1),
        // Types (capitalized identifiers)
        (#"\b([A-Z][A-Za-z0-9_]*)\b"#, blue, 1),
        // Function calls
        (#"\b([a-z_][A-Za-z0-9_]*)\s*\("#, yellow, 1),
    ])

    // MARK: - Python Rules

    private static let pythonRules: [TokenRule] = makeRules([
        // Comments
        (#"(#[^\n]*)"#, gray, 1),
        // Strings (triple first, then single/double)
        (#"("""[\s\S]*?"""|'''[\s\S]*?''')"#, green, 1),
        (#"('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")"#, green, 1),
        // Numbers
        (#"\b(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, orange, 1),
        // Keywords
        (#"\b(def|class|if|elif|else|for|while|in|not|and|or|return|import|from|as|with|try|except|finally|raise|pass|break|continue|lambda|yield|global|nonlocal|del|assert|True|False|None|async|await)\b"#, purple, 1),
        // Types / Builtins
        (#"\b(int|str|float|bool|list|dict|set|tuple|type|object|Exception|TypeError|ValueError|KeyError|IndexError|AttributeError|None)\b"#, blue, 1),
        // Function calls
        (#"\b([a-z_][A-Za-z0-9_]*)\s*\("#, yellow, 1),
    ])

    // MARK: - Bash Rules

    private static let bashRules: [TokenRule] = makeRules([
        // Comments
        (#"(#[^\n]*)"#, gray, 1),
        // Strings
        (#"("(?:[^"\\]|\\.)*"|'[^']*')"#, green, 1),
        // Variables
        (#"(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)"#, orange, 1),
        // Keywords
        (#"\b(if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|local|export|readonly|source|echo|cd|ls|mkdir|rm|cp|mv|cat|grep|awk|sed|find|chmod|chown|exit|set|unset|shift|break|continue)\b"#, purple, 1),
    ])

    // MARK: - JSON Rules

    private static let jsonRules: [TokenRule] = makeRules([
        // String keys (before values to get distinct color)
        (#"("(?:[^"\\]|\\.)*")\s*:"#, blue, 1),
        // String values
        (#":\s*("(?:[^"\\]|\\.)*")"#, green, 1),
        // Numbers
        (#":\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, orange, 1),
        // Booleans and null
        (#"\b(true|false|null)\b"#, purple, 1),
    ])

    // MARK: - Rule Builder Helper

    private static func makeRules(_ specs: [(String, NSColor, Int)]) -> [TokenRule] {
        specs.compactMap { pattern, color, group in
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return TokenRule(pattern: re, color: color, captureGroup: group)
        }
    }
}

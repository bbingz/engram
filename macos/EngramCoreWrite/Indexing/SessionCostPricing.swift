import Foundation
import EngramCoreRead

internal struct SessionModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

internal enum SessionCostPricing {
    static let tableVersion = "2"
    static let metadataKey = "session_cost_pricing_version"

    private static let codexLongContextThreshold = 272_000
    private static let million = 1_000_000.0

    private static let claudeBase = SessionModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
    private static let opusCurrent = SessionModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
    private static let opusLegacy = SessionModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
    private static let haikuCurrent = SessionModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)
    private static let haiku35 = SessionModelPrice(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1)
    private static let haiku3 = SessionModelPrice(input: 0.25, output: 1.25, cacheRead: 0.03, cacheWrite: 0.3)

    private static let claudeExactPricing: [String: ResolvedPrice] = [
        "claude-opus-4-8": ResolvedPrice(price: opusCurrent),
        "claude-opus-4-7": ResolvedPrice(price: opusCurrent),
        "claude-opus-4-6": ResolvedPrice(price: opusCurrent),
        "claude-opus-4-5": ResolvedPrice(price: opusCurrent),
        "claude-opus-4-1": ResolvedPrice(price: opusLegacy),
        "claude-opus-4": ResolvedPrice(price: opusLegacy),
        "claude-sonnet-4-6": ResolvedPrice(price: claudeBase),
        "claude-sonnet-4-5": ResolvedPrice(price: claudeBase),
        "claude-sonnet-4": ResolvedPrice(price: claudeBase),
        "claude-sonnet-3-7": ResolvedPrice(price: claudeBase),
        "claude-sonnet-3-5": ResolvedPrice(price: claudeBase),
        "claude-haiku-4-5": ResolvedPrice(price: haikuCurrent),
        "claude-haiku-3-5": ResolvedPrice(price: haiku35),
        "claude-haiku-3": ResolvedPrice(price: haiku3),
    ]

    private static let gptPricing: [String: ResolvedPrice] = [
        "gpt-5.1-codex-max": ResolvedPrice(price: SessionModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
        "gpt-5.1-codex": ResolvedPrice(price: SessionModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
        "gpt-5.1": ResolvedPrice(price: SessionModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
        "gpt-5": ResolvedPrice(price: SessionModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
        "gpt-5.2-codex": ResolvedPrice(price: SessionModelPrice(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0)),
        "gpt-5.2": ResolvedPrice(price: SessionModelPrice(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0)),
        "gpt-5.3-codex-spark": ResolvedPrice(price: SessionModelPrice(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0)),
        "gpt-5.3-codex": ResolvedPrice(price: SessionModelPrice(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0)),
        "gpt-5.3": ResolvedPrice(price: SessionModelPrice(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 0)),
        "gpt-5.4-mini": ResolvedPrice(price: SessionModelPrice(input: 0.75, output: 4.5, cacheRead: 0.075, cacheWrite: 0)),
        "gpt-5.4-nano": ResolvedPrice(price: SessionModelPrice(input: 0.2, output: 1.25, cacheRead: 0.02, cacheWrite: 0)),
        "gpt-5.4-pro": ResolvedPrice(
            price: SessionModelPrice(input: 30, output: 180, cacheRead: 30, cacheWrite: 0),
            tier: .threshold(codexLongContextThreshold, SessionModelPrice(input: 60, output: 270, cacheRead: 60, cacheWrite: 0))
        ),
        "gpt-5.5-pro": ResolvedPrice(
            price: SessionModelPrice(input: 30, output: 180, cacheRead: 30, cacheWrite: 0),
            tier: .threshold(codexLongContextThreshold, SessionModelPrice(input: 60, output: 270, cacheRead: 60, cacheWrite: 0))
        ),
        "gpt-5.5": ResolvedPrice(
            price: SessionModelPrice(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 0),
            tier: .threshold(codexLongContextThreshold, SessionModelPrice(input: 10, output: 45, cacheRead: 1, cacheWrite: 0))
        ),
        "gpt-5.4": ResolvedPrice(
            price: SessionModelPrice(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 0),
            tier: .threshold(codexLongContextThreshold, SessionModelPrice(input: 5, output: 22.5, cacheRead: 0.5, cacheWrite: 0))
        ),
    ]

    private static let legacyOpenAIAndGeminiPricing: [String: ResolvedPrice] = [
        "gpt-4o-mini": ResolvedPrice(price: SessionModelPrice(input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0.15)),
        "gpt-4o": ResolvedPrice(price: SessionModelPrice(input: 2.5, output: 10, cacheRead: 1.25, cacheWrite: 2.5)),
        "gpt-4.1": ResolvedPrice(price: SessionModelPrice(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 2)),
        "o3-mini": ResolvedPrice(price: SessionModelPrice(input: 1.1, output: 4.4, cacheRead: 0.55, cacheWrite: 1.1)),
        "o4-mini": ResolvedPrice(price: SessionModelPrice(input: 1.1, output: 4.4, cacheRead: 0.55, cacheWrite: 1.1)),
        "gemini-2.0-flash": ResolvedPrice(price: SessionModelPrice(input: 0.1, output: 0.4, cacheRead: 0.025, cacheWrite: 0.1)),
        "gemini-2.5-pro": ResolvedPrice(price: SessionModelPrice(input: 1.25, output: 10, cacheRead: 0.31, cacheWrite: 1.25)),
    ]

    private static let reasoningTiers: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "auto", "none"]

    static func price(for model: String?) -> SessionModelPrice? {
        resolvedPrice(for: model)?.price
    }

    static func computeCost(model: String?, usage: TokenUsage) -> Double? {
        guard let resolved = resolvedPrice(for: model) else { return nil }
        return cost(tokens: usage.inputTokens, baseRate: resolved.price.input, tier: resolved.tier?.input)
            + cost(tokens: usage.outputTokens, baseRate: resolved.price.output, tier: resolved.tier?.output)
            + cost(tokens: usage.cacheReadTokens ?? 0, baseRate: resolved.price.cacheRead, tier: resolved.tier?.cacheRead)
            + cost(tokens: usage.cacheCreationTokens ?? 0, baseRate: resolved.price.cacheWrite, tier: resolved.tier?.cacheWrite)
    }

    private static func resolvedPrice(for model: String?) -> ResolvedPrice? {
        guard let model = normalized(model) else { return nil }
        if let claude = resolveClaude(model) { return claude }
        if let openAI = resolveOpenAI(model) { return openAI }
        if isOpenAIModel(model) { return nil }
        return longestDelimitedMatch(model, in: legacyOpenAIAndGeminiPricing)
    }

    private static func normalized(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !model.isEmpty
        else {
            return nil
        }
        return model
    }

    private static func resolveClaude(_ model: String) -> ResolvedPrice? {
        var normalized = model
        if normalized.hasPrefix("anthropic/") {
            normalized.removeFirst("anthropic/".count)
        } else if normalized.hasPrefix("anthropic:") {
            normalized.removeFirst("anthropic:".count)
        }
        normalized = normalized.replacingOccurrences(of: ".", with: "-")
        if normalized.hasSuffix("-thinking") {
            normalized.removeLast("-thinking".count)
        }

        if let exact = claudeExactPricing[normalized] {
            return exact
        }
        if let snapshotBase = stripSnapshotSuffix(normalized),
           let exact = claudeExactPricing[snapshotBase] {
            return exact
        }

        switch normalized {
        case "opus-4":
            return claudeExactPricing["claude-opus-4-8"]
        case "sonnet-4":
            return claudeExactPricing["claude-sonnet-4-6"]
        case "haiku-4":
            return claudeExactPricing["claude-haiku-4-5"]
        default:
            break
        }

        if hasClaudeFamilyPrefix(normalized, family: "opus", major: "4") {
            return claudeExactPricing["claude-opus-4-8"]
        }
        if hasClaudeFamilyPrefix(normalized, family: "sonnet", major: "4") {
            return claudeExactPricing["claude-sonnet-4-6"]
        }
        if hasClaudeFamilyPrefix(normalized, family: "haiku", major: "4") {
            return claudeExactPricing["claude-haiku-4-5"]
        }

        return longestDelimitedMatch(normalized, in: claudeExactPricing)
    }

    private static func resolveOpenAI(_ model: String) -> ResolvedPrice? {
        guard isOpenAIModel(model),
              let normalized = normalizedOpenAIModel(model)
        else {
            return nil
        }
        return longestDelimitedMatch(normalized, in: gptPricing)
            ?? longestDelimitedMatch(normalized, in: legacyOpenAIAndGeminiPricing)
    }

    private static func normalizedOpenAIModel(_ model: String) -> String? {
        guard var normalized = stripParenthesizedReasoning(model) else { return nil }
        for _ in 0..<4 {
            guard let tier = reasoningTiers.first(where: { normalized.hasSuffix("-\($0)") }) else {
                break
            }
            normalized.removeLast(tier.count + 1)
        }
        return normalized
    }

    private static func isOpenAIModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-") || model.hasPrefix("o3-") || model.hasPrefix("o4-")
    }

    private static func stripParenthesizedReasoning(_ model: String) -> String? {
        guard model.hasSuffix(")") else { return model }
        guard let open = model.lastIndex(of: "(") else { return model }
        let contentStart = model.index(after: open)
        let contentEnd = model.index(before: model.endIndex)
        let content = model[contentStart..<contentEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard reasoningTiers.contains(content) else { return nil }
        return model[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSnapshotSuffix(_ model: String) -> String? {
        for separator in ["-", "@"] {
            guard let range = model.range(of: separator, options: .backwards) else { continue }
            let suffix = model[range.upperBound...]
            guard suffix.count == 8, suffix.allSatisfy(\.isNumber), suffix.hasPrefix("20") else { continue }
            return String(model[..<range.lowerBound])
        }
        return nil
    }

    private static func hasClaudeFamilyPrefix(_ model: String, family: String, major: String) -> Bool {
        let prefix = "claude-\(family)-\(major)-"
        guard model.hasPrefix(prefix) else { return false }
        let remainder = model.dropFirst(prefix.count)
        return remainder.first?.isNumber == true
    }

    private static func longestDelimitedMatch(_ model: String, in pricing: [String: ResolvedPrice]) -> ResolvedPrice? {
        if let exact = pricing[model] {
            return exact
        }
        return pricing.keys
            .sorted { $0.count > $1.count }
            .first { key in
                guard model.hasPrefix(key), model.count > key.count else { return false }
                let boundary = model[model.index(model.startIndex, offsetBy: key.count)]
                return !boundary.isNumber && boundary != "."
            }
            .flatMap { pricing[$0] }
    }

    private static func cost(tokens: Int, baseRate: Double, tier: TierRate?) -> Double {
        guard tokens > 0, baseRate > 0 || tier != nil else { return 0 }
        guard let tier else {
            return Double(tokens) / million * baseRate
        }
        let baseTokens = min(tokens, tier.threshold)
        let tierTokens = max(tokens - tier.threshold, 0)
        return Double(baseTokens) / million * baseRate
            + Double(tierTokens) / million * tier.rate
    }

    private struct ResolvedPrice {
        var price: SessionModelPrice
        var tier: ResolvedTier?
    }

    private struct ResolvedTier {
        var input: TierRate
        var output: TierRate
        var cacheRead: TierRate
        var cacheWrite: TierRate

        static func threshold(_ threshold: Int, _ rate: SessionModelPrice) -> ResolvedTier {
            ResolvedTier(
                input: TierRate(threshold: threshold, rate: rate.input),
                output: TierRate(threshold: threshold, rate: rate.output),
                cacheRead: TierRate(threshold: threshold, rate: rate.cacheRead),
                cacheWrite: TierRate(threshold: threshold, rate: rate.cacheWrite)
            )
        }
    }

    private struct TierRate {
        var threshold: Int
        var rate: Double
    }
}

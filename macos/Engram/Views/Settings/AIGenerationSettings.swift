import Foundation

/// Pure, testable transform for the AI-summary "generation" settings block.
///
/// Extracted from `AISettingsSection` so the persist→restore round trip — and
/// the collapse-then-edit data-loss regression that used to gate persistence on
/// the DisclosureGroup expansion flags — can be unit-tested without a SwiftUI
/// view. Defaults mirror the `AISettingsSection` @State defaults.
struct AIGenerationSettings: Equatable {
    var maxTokens: Int = 200
    var temperature: Double = 0.3
    var sampleFirst: Int = 20
    var sampleLast: Int = 30
    var truncateChars: Int = 500

    /// Write every value unconditionally. Persistence must NOT be gated on UI
    /// expansion state — collapsing a disclosure group must not drop saved values.
    func write(into settings: inout [String: Any]) {
        settings["summaryMaxTokens"] = maxTokens
        settings["summaryTemperature"] = temperature
        settings["summarySampleFirst"] = sampleFirst
        settings["summarySampleLast"] = sampleLast
        settings["summaryTruncateChars"] = truncateChars
    }

    /// Restore, falling back to the default for any missing or mistyped key.
    static func read(from settings: [String: Any]) -> AIGenerationSettings {
        var g = AIGenerationSettings()
        if let v = settings["summaryMaxTokens"] as? Int { g.maxTokens = v }
        if let v = settings["summaryTemperature"] as? Double { g.temperature = v }
        if let v = settings["summarySampleFirst"] as? Int { g.sampleFirst = v }
        if let v = settings["summarySampleLast"] as? Int { g.sampleLast = v }
        if let v = settings["summaryTruncateChars"] as? Int { g.truncateChars = v }
        return g
    }
}

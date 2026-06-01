import Foundation

public enum SharedSystemMessageCategory: String, Sendable {
    case none
    case systemPrompt
    case agentComm
}

public enum SystemMessageClassifier {
    public static func classify(content: String, source: String) -> SharedSystemMessageCategory {
        let prefixContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = source.lowercased()
        let isAntigravity = source == "antigravity" || source == "antigravity-legacy"

        if prefixContent.hasPrefix("# AGENTS.md instructions for ") ||
            content.contains("<INSTRUCTIONS>") ||
            prefixContent.hasPrefix("<system-reminder>") ||
            prefixContent.hasPrefix("<environment_context>") ||
            prefixContent.hasPrefix("<EXTREMELY_IMPORTANT>") ||
            (isAntigravity && prefixContent.hasPrefix("<SYSTEM_MESSAGE>")) ||
            (isAntigravity && prefixContent.hasPrefix("The following is a <SYSTEM_MESSAGE>")) ||
            prefixContent.hasPrefix("You are Qwen Code") {
            return .systemPrompt
        }

        if prefixContent.hasPrefix("<subagent_notification>") ||
            prefixContent.hasPrefix("<local-command-caveat>") ||
            prefixContent.hasPrefix("<local-command-stdout>") ||
            content.contains("<command-name>") ||
            content.contains("<command-message>") ||
            prefixContent.hasPrefix("Unknown skill: ") ||
            prefixContent.hasPrefix("Invoke the superpowers:") ||
            prefixContent.hasPrefix("Base directory for this skill:") {
            return .agentComm
        }

        return .none
    }
}

// macos/Engram/Models/MessageTypeClassifier.swift
import Foundation
import SwiftUI

enum MessageType: String, CaseIterable {
    case user
    case assistant
    case tool
    case error
    case code
    case system

    var label: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool: return "Tools"
        case .error: return "Error"
        case .code: return "Code"
        case .system: return "System"
        }
    }

    var color: Color {
        switch self {
        case .user:      return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .assistant: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .tool:      return Color(red: 0.06, green: 0.73, blue: 0.51)
        case .error:     return Color(red: 0.94, green: 0.27, blue: 0.27)
        case .code:      return Color(red: 0.39, green: 0.40, blue: 0.95)
        case .system:    return Color.secondary
        }
    }

    static var chipTypes: [MessageType] { [.user, .assistant, .tool, .error, .code] }
}

struct MessageTypeClassifier {

    private static let toolPatterns: [String] = [
        "Tool:", "tool_call", "tool_result",
        "Read(", "Write(", "Edit(", "Bash(",
        "Grep(", "Glob(", "Agent(",
        "› tool:", "⟪out⟫"
    ]

    private static let errorPatterns: [String] = [
        "Error:", "error:", "ERROR",
        "permission denied", "Permission denied",
        "not found", "Not found",
        "Exit code: 1", "exit code 1",
        "Command failed", "command failed"
    ]

    static func classify(_ message: ChatMessage) -> MessageType {
        if message.systemCategory == .systemPrompt {
            return .system
        }
        if message.systemCategory == .agentComm {
            return .tool
        }
        if message.role == "user" {
            return .user
        }
        let content = message.content
        if containsErrorPattern(content) {
            return .error
        }
        if containsToolPattern(content) {
            return .tool
        }
        if message.role == "assistant" && hasSignificantCodeBlock(content) {
            return .code
        }
        if message.role == "assistant" {
            return .assistant
        }
        return .assistant
    }

    private static func containsToolPattern(_ text: String) -> Bool {
        let prefix = text.prefix(500)
        return toolPatterns.contains { prefix.contains($0) }
    }

    private static func containsErrorPattern(_ text: String) -> Bool {
        let prefix = text.prefix(1000)
        return errorPatterns.contains { prefix.contains($0) }
    }

    private static func hasSignificantCodeBlock(_ text: String) -> Bool {
        guard text.contains("```") else { return false }
        let codeLen = text.components(separatedBy: "```")
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map(\.element.count)
            .reduce(0, +)
        return codeLen > text.count / 2
    }
}

// macos/Engram/Views/Transcript/TranscriptText.swift
import Foundation

/// Pure helpers for turning indexed transcript rows into copyable plain text.
/// Extracted so the "Copy Entire Conversation" action has a single, testable
/// source of truth shared by the toolbar and the per-message context menu.
enum TranscriptText {
    static func rolePrefix(for type: MessageType) -> String {
        switch type {
        case .user:       return "> "
        case .assistant:  return ""
        case .tool:       return "› "
        case .toolCall:   return "› "
        case .toolResult: return "‹ "
        case .thinking:   return "~ "
        case .error:      return "! "
        case .code:       return "```\n"
        case .system:     return "[system] "
        }
    }

    static func conversationText(_ indexed: [IndexedMessage]) -> String {
        indexed
            .map { rolePrefix(for: $0.messageType) + $0.message.content }
            .joined(separator: "\n\n")
    }
}

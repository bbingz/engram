// macos/Engram/Core/AIClient.swift
import Foundation

enum AIProvider: String, CaseIterable {
    case openai = "openai"
    case anthropic = "anthropic"
}

struct AISettings: Codable {
    var aiProvider: String?
    var openaiApiKey: String?
    var openaiModel: String?
    var anthropicApiKey: String?
    var anthropicModel: String?
}

enum AIClientError: Error {
    case noAPIKey
    case invalidResponse
    case apiError(String)
}

@MainActor
class AIClient {
    static let shared = AIClient()

    private init() {}

    func loadSettings() -> AISettings {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/settings.json")

        guard let data = try? Data(contentsOf: configPath),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return AISettings()
        }
        return settings
    }

    func generateSummary(messages: [ChatMessage]) async throws -> String {
        let settings = loadSettings()
        let provider = AIProvider(rawValue: settings.aiProvider ?? "openai") ?? .openai

        switch provider {
        case .openai:
            return try await generateSummaryWithOpenAI(messages: messages, settings: settings)
        case .anthropic:
            return try await generateSummaryWithAnthropic(messages: messages, settings: settings)
        }
    }

    private func generateSummaryWithOpenAI(messages: [ChatMessage], settings: AISettings) async throws -> String {
        guard let apiKey = settings.openaiApiKey, !apiKey.isEmpty else {
            throw AIClientError.noAPIKey
        }

        let model = settings.openaiModel ?? "gpt-4o-mini"

        // Format messages for summarization
        let conversationText = formatMessagesForSummary(messages)

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "请用 2-3 句话总结以下 AI 编程对话的核心内容。总结应包括：1) 主要讨论的问题或任务 2) 达成的结论、解决方案或关键成果。保持简洁，使用中文回复。"],
                ["role": "user", "content": "请总结以下对话：\n\n\(conversationText)"]
            ],
            "max_tokens": 200,
            "temperature": 0.3
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIClientError.apiError(message)
            }
            throw AIClientError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIClientError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateSummaryWithAnthropic(messages: [ChatMessage], settings: AISettings) async throws -> String {
        guard let apiKey = settings.anthropicApiKey, !apiKey.isEmpty else {
            throw AIClientError.noAPIKey
        }

        let model = settings.anthropicModel ?? "claude-3-haiku-20240307"
        let conversationText = formatMessagesForSummary(messages)

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 200,
            "temperature": 0.3,
            "system": "请用 2-3 句话总结以下 AI 编程对话的核心内容。总结应包括：1) 主要讨论的问题或任务 2) 达成的结论、解决方案或关键成果。保持简洁，使用中文回复。",
            "messages": [
                ["role": "user", "content": "请总结以下对话：\n\n\(conversationText)"]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIClientError.apiError(message)
            }
            throw AIClientError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIClientError.invalidResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatMessagesForSummary(_ messages: [ChatMessage]) -> String {
        // Take first 20 and last 30 messages to capture beginning and end
        let limitedMessages = messages.count <= 50
            ? messages
            : Array(messages.prefix(20) + messages.suffix(30))

        return limitedMessages.map { msg in
            let content = msg.content.count > 500 ? String(msg.content.prefix(500)) + "..." : msg.content
            return "[\(msg.role)] \(content)"
        }.joined(separator: "\n\n")
    }
}

// macos/Engram/Views/Settings/AISettingsSection.swift
import SwiftUI

struct AISettingsSection: View {
    @Environment(EngramServiceClient.self) var serviceClient

    // Provider
    @State private var aiProtocol: String = "openai"
    @State private var aiBaseURL: String = ""
    @State private var aiApiKey: String = ""
    @State private var aiModel: String = "gpt-4o-mini"

    // NOTE (advertised-but-inert removal): the Embeddings controls (provider /
    // model / dimension / Ollama URL) were removed here. No Swift runtime code
    // constructs an embedding client, loads sqlite-vec, or reads these settings —
    // semantic search/embeddings are not implemented — so the controls promised a
    // capability that silently no-ops. Do not re-add until a real embedding path
    // ships. (Defect: false UI promise, not a missing backend.)

    // Prompt template
    @State private var summaryLanguage: String = "中文"
    @State private var summaryMaxSentences: Int = 3
    @State private var summaryStyle: String = ""
    @State private var summaryPrompt: String = ""
    @State private var showCustomPrompt: Bool = false

    // Generation config
    @State private var summaryPreset: String = "standard"
    @State private var summaryMaxTokens: Int = 200
    @State private var summaryTemperature: Double = 0.3
    @State private var showCustomGeneration: Bool = false
    @State private var summarySampleFirst: Int = 20
    @State private var summarySampleLast: Int = 30
    @State private var summaryTruncateChars: Int = 500
    @State private var showAdvancedGeneration: Bool = false

    // Auto-summary
    @State private var autoSummary: Bool = false
    @State private var autoSummaryCooldown: Int = 5
    @State private var autoSummaryMinMessages: Int = 4
    @State private var autoSummaryRefresh: Bool = false
    @State private var autoSummaryRefreshThreshold: Int = 20

    // Title generation
    @State private var titleProvider: String = "ollama"
    @State private var titleBaseURL: String = ""
    @State private var titleModel: String = "qwen2.5:3b"
    @State private var titleApiKey: String = ""
    @State private var titleAutoGenerate: Bool = false
    @State private var titleTestStatus: TitleConnectionStatus = .idle
    @State private var titleRegenerateStatus: TitleRegenerationStatus = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "brain", title: "AI Summary")

            // Provider
            GroupBox("Provider") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Protocol", selection: $aiProtocol) {
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                        Text("Gemini").tag("gemini")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: aiProtocol) { saveAISettings() }

                    HStack {
                        Text("Base URL")
                        Spacer()
                        TextField("Default", text: $aiBaseURL)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiBaseURL) { saveAISettings() }
                    }
                    Text(defaultBaseURL(for: aiProtocol))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("Required", text: $aiApiKey)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiApiKey) { saveAISettings() }
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        TextField("gpt-4o-mini", text: $aiModel)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiModel) { saveAISettings() }
                    }

                    Text("API keys are stored in macOS Keychain")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // Embeddings controls removed — see note on state above.

            // Prompt Template
            GroupBox("Summary Prompt") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Language", selection: $summaryLanguage) {
                        Text("中文").tag("中文")
                        Text("English").tag("English")
                        Text("日本語").tag("日本語")
                    }
                    .onChange(of: summaryLanguage) { saveAISettings() }

                    Stepper("Max Sentences: \(summaryMaxSentences)", value: $summaryMaxSentences, in: 1...10)
                        .onChange(of: summaryMaxSentences) { saveAISettings() }

                    HStack {
                        Text("Style")
                        Spacer()
                        TextField("Optional, e.g. 技术向", text: $summaryStyle)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: summaryStyle) { saveAISettings() }
                    }

                    DisclosureGroup("Custom Prompt", isExpanded: $showCustomPrompt) {
                        TextEditor(text: $summaryPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .onChange(of: summaryPrompt) { saveAISettings() }
                        Text("Variables: {{language}}, {{maxSentences}}, {{style}}")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Generation
            GroupBox("Generation") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preset", selection: $summaryPreset) {
                        Text("Concise").tag("concise")
                        Text("Standard").tag("standard")
                        Text("Detailed").tag("detailed")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: summaryPreset) { saveAISettings() }

                    DisclosureGroup("Custom", isExpanded: $showCustomGeneration) {
                        HStack {
                            Text("Max Tokens")
                            Spacer()
                            TextField("200", value: $summaryMaxTokens, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summaryMaxTokens) { saveAISettings() }
                        }
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Slider(value: $summaryTemperature, in: 0...1, step: 0.1)
                                .frame(width: 160)
                                .onChange(of: summaryTemperature) { saveAISettings() }
                            Text(String(format: "%.1f", summaryTemperature))
                                .font(.caption)
                                .frame(width: 30)
                        }
                    }

                    DisclosureGroup("Advanced", isExpanded: $showAdvancedGeneration) {
                        HStack {
                            Text("Sample First")
                            Spacer()
                            TextField("20", value: $summarySampleFirst, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summarySampleFirst) { saveAISettings() }
                            Text("messages")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Sample Last")
                            Spacer()
                            TextField("30", value: $summarySampleLast, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summarySampleLast) { saveAISettings() }
                            Text("messages")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Truncate")
                            Spacer()
                            TextField("500", value: $summaryTruncateChars, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summaryTruncateChars) { saveAISettings() }
                            Text("chars/msg")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Auto Summary
            GroupBox("Auto Summary") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Auto-generate summaries", isOn: $autoSummary)
                        .onChange(of: autoSummary) { saveAISettings() }
                    if autoSummary {
                        Stepper("Cooldown: \(autoSummaryCooldown) min", value: $autoSummaryCooldown, in: 1...30)
                            .onChange(of: autoSummaryCooldown) { saveAISettings() }
                        Stepper("Min messages: \(autoSummaryMinMessages)", value: $autoSummaryMinMessages, in: 1...50)
                            .onChange(of: autoSummaryMinMessages) { saveAISettings() }
                        Toggle("Periodically refresh", isOn: $autoSummaryRefresh)
                            .onChange(of: autoSummaryRefresh) { saveAISettings() }
                        if autoSummaryRefresh {
                            Stepper("Refresh after \(autoSummaryRefreshThreshold) new messages",
                                    value: $autoSummaryRefreshThreshold, in: 5...100, step: 5)
                                .onChange(of: autoSummaryRefreshThreshold) { saveAISettings() }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            // Title Generation
            GroupBox("Title Generation") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Provider", selection: $titleProvider) {
                        Text("Ollama").tag("ollama")
                        Text("OpenAI").tag("openai")
                        Text("Dashscope").tag("dashscope")
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: titleProvider) { saveTitleSettings() }

                    HStack {
                        Text("URL")
                        Spacer()
                        TextField(titleProvider == "ollama" ? "http://localhost:11434" : "Base URL", text: $titleBaseURL)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: titleBaseURL) { saveTitleSettings() }
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        TextField("qwen2.5:3b", text: $titleModel)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: titleModel) { saveTitleSettings() }
                    }

                    if titleProvider != "ollama" {
                        HStack {
                            Text("API Key")
                            Spacer()
                            SecureField("Required", text: $titleApiKey)
                                .frame(width: 260)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: titleApiKey) { saveTitleSettings() }
                        }
                    }

                    Toggle("Auto-generate titles", isOn: $titleAutoGenerate)
                        .onChange(of: titleAutoGenerate) { saveTitleSettings() }

                    HStack(spacing: 8) {
                        Button("Test Connection") {
                            titleTestStatus = .testing
                            let url = titleBaseURL.isEmpty ? "http://localhost:11434" : titleBaseURL
                            let testURL = titleProvider == "ollama"
                                ? "\(url)/api/tags"
                                : appendAPIPath("/v1/chat/completions", to: url)
                            Task {
                                do {
                                    var req = URLRequest(url: URL(string: testURL)!)
                                    if titleProvider != "ollama" {
                                        req.httpMethod = "POST"
                                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                        req.httpBody = try JSONSerialization.data(withJSONObject: [
                                            "model": normalizeOpenAICompatibleModel(titleModel, baseURL: url),
                                            "messages": [["role": "user", "content": "Return exactly: ok"]],
                                            "max_tokens": 8,
                                            "temperature": 0
                                        ])
                                    }
                                    if !titleApiKey.isEmpty {
                                        req.setValue("Bearer \(titleApiKey)", forHTTPHeaderField: "Authorization")
                                    }
                                    let (_, resp) = try await URLSession.shared.data(for: req)
                                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                                    titleTestStatus = code == 200 ? .connected : (code == 429 ? .quotaExhausted : .http(code))
                                } catch {
                                    titleTestStatus = .failed(error.localizedDescription)
                                }
                            }
                        }
                        .buttonStyle(.bordered)

                        if let label = titleTestStatus.label {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(titleTestStatus.isSuccess ? .green : .red)
                        }

                        Spacer()

                        Button("Regenerate All") {
                            titleRegenerateStatus = .queued
                            Task {
                                do {
                                    let response = try await serviceClient.regenerateAllTitles()
                                    titleRegenerateStatus = .service(response.status)
                                } catch {
                                    titleRegenerateStatus = .error
                                }
                            }
                        }
                        .buttonStyle(.bordered)

                        if let label = titleRegenerateStatus.label {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { loadAISettings() }
    }

    // MARK: - Helpers

    private func defaultBaseURL(for proto: String) -> String {
        switch proto {
        case "anthropic": return "Default: https://api.anthropic.com"
        case "gemini": return "Default: https://generativelanguage.googleapis.com"
        default: return "Default: https://api.openai.com"
        }
    }

    private func saveAISettings() {
        // Try Keychain first; fall back to plaintext JSON for ad-hoc builds
        if !aiApiKey.isEmpty {
            let saved = KeychainHelper.set("aiApiKey", value: aiApiKey)
            if saved {
                mutateEngramSettings { $0["aiApiKey"] = "@keychain" }
            } else {
                // Keychain unavailable (ad-hoc build) — store in JSON
                mutateEngramSettings { $0["aiApiKey"] = aiApiKey }
            }
        } else {
            KeychainHelper.delete("aiApiKey")
            mutateEngramSettings { $0.removeValue(forKey: "aiApiKey") }
        }
        mutateEngramSettings { settings in
            settings["aiProtocol"] = aiProtocol
            if !aiBaseURL.isEmpty { settings["aiBaseURL"] = aiBaseURL } else { settings.removeValue(forKey: "aiBaseURL") }
            settings["aiModel"] = normalizeOpenAICompatibleModel(aiModel, baseURL: aiBaseURL)

            settings["summaryLanguage"] = summaryLanguage
            settings["summaryMaxSentences"] = summaryMaxSentences
            if !summaryStyle.isEmpty { settings["summaryStyle"] = summaryStyle } else { settings.removeValue(forKey: "summaryStyle") }
            if !summaryPrompt.isEmpty { settings["summaryPrompt"] = summaryPrompt } else { settings.removeValue(forKey: "summaryPrompt") }

            settings["summaryPreset"] = summaryPreset
            // Persist current generation values unconditionally. These used to be
            // gated on the DisclosureGroup expansion flags (showCustomGeneration /
            // showAdvancedGeneration), but those flags only track whether the
            // section is expanded in the UI — collapsing a group silently deleted
            // the user's saved values. The state vars always hold valid values, so
            // writing them is safe and idempotent.
            AIGenerationSettings(
                maxTokens: summaryMaxTokens,
                temperature: summaryTemperature,
                sampleFirst: summarySampleFirst,
                sampleLast: summarySampleLast,
                truncateChars: summaryTruncateChars
            ).write(into: &settings)

            settings["autoSummary"] = autoSummary
            settings["autoSummaryCooldown"] = autoSummaryCooldown
            settings["autoSummaryMinMessages"] = autoSummaryMinMessages
            settings["autoSummaryRefresh"] = autoSummaryRefresh
            settings["autoSummaryRefreshThreshold"] = autoSummaryRefreshThreshold
        }
    }

    private func saveTitleSettings() {
        // Try Keychain first; fall back to plaintext JSON for ad-hoc builds
        if titleProvider != "ollama" && !titleApiKey.isEmpty {
            let saved = KeychainHelper.set("titleApiKey", value: titleApiKey)
            if saved {
                mutateEngramSettings { $0["titleApiKey"] = "@keychain" }
            } else {
                mutateEngramSettings { $0["titleApiKey"] = titleApiKey }
            }
        } else {
            KeychainHelper.delete("titleApiKey")
            mutateEngramSettings { $0.removeValue(forKey: "titleApiKey") }
        }
        mutateEngramSettings { settings in
            settings["titleProvider"] = titleProvider
            if !titleBaseURL.isEmpty {
                settings["titleBaseUrl"] = titleBaseURL
                settings.removeValue(forKey: "titleBaseURL")
            } else {
                settings.removeValue(forKey: "titleBaseUrl")
                settings.removeValue(forKey: "titleBaseURL")
            }
            settings["titleModel"] = normalizeOpenAICompatibleModel(titleModel, baseURL: titleBaseURL)
            // titleApiKey handled above via Keychain
            settings["titleAutoGenerate"] = titleAutoGenerate
        }
    }

    private func loadAISettings() {
        guard let settings = readEngramSettings() else { return }

        if let v = settings["aiProtocol"] as? String { aiProtocol = v }
        if let v = settings["aiBaseURL"] as? String { aiBaseURL = v }
        aiApiKey = KeychainHelper.get("aiApiKey")
            ?? { let v = settings["aiApiKey"] as? String; return v == "@keychain" ? nil : v }() ?? ""
        if let v = settings["aiModel"] as? String { aiModel = normalizeOpenAICompatibleModel(v, baseURL: aiBaseURL) }

        if let v = settings["summaryLanguage"] as? String { summaryLanguage = v }
        if let v = settings["summaryMaxSentences"] as? Int { summaryMaxSentences = v }
        if let v = settings["summaryStyle"] as? String { summaryStyle = v }
        if let v = settings["summaryPrompt"] as? String { summaryPrompt = v }

        if let v = settings["summaryPreset"] as? String { summaryPreset = v }
        // Persistence is now unconditional, so these keys always exist. Auto-expand
        // a disclosure group only when a persisted value differs from its default,
        // preserving the "expand when customized" UX without coupling save to it.
        let gen = AIGenerationSettings.read(from: settings)
        summaryMaxTokens = gen.maxTokens
        summaryTemperature = gen.temperature
        showCustomGeneration = summaryMaxTokens != 200 || summaryTemperature != 0.3
        summarySampleFirst = gen.sampleFirst
        summarySampleLast = gen.sampleLast
        summaryTruncateChars = gen.truncateChars
        showAdvancedGeneration = summarySampleFirst != 20 || summarySampleLast != 30 || summaryTruncateChars != 500

        if let v = settings["autoSummary"] as? Bool { autoSummary = v }
        if let v = settings["autoSummaryCooldown"] as? Int { autoSummaryCooldown = v }
        if let v = settings["autoSummaryMinMessages"] as? Int { autoSummaryMinMessages = v }
        if let v = settings["autoSummaryRefresh"] as? Bool { autoSummaryRefresh = v }
        if let v = settings["autoSummaryRefreshThreshold"] as? Int { autoSummaryRefreshThreshold = v }

        if let v = settings["titleProvider"] as? String { titleProvider = v }
        if let v = settings["titleBaseUrl"] as? String { titleBaseURL = v }
        else if let v = settings["titleBaseURL"] as? String { titleBaseURL = v }
        if let v = settings["titleModel"] as? String { titleModel = normalizeOpenAICompatibleModel(v, baseURL: titleBaseURL) }
        titleApiKey = KeychainHelper.get("titleApiKey")
            ?? { let v = settings["titleApiKey"] as? String; return v == "@keychain" ? nil : v }() ?? ""
        if let v = settings["titleAutoGenerate"] as? Bool { titleAutoGenerate = v }
    }

    private func appendAPIPath(_ path: String, to baseURL: String) -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.hasSuffix("/v1"), path.hasPrefix("/v1/") {
            return base + String(path.dropFirst(3))
        }
        return base + path
    }

    private func normalizeOpenAICompatibleModel(_ model: String, baseURL: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard baseURL.range(of: #"xiaomimimo\.com|mimo-v2\.com"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return trimmed
        }
        if trimmed.range(of: #"^mimo-\d"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed.replacingOccurrences(
                of: #"^mimo-"#,
                with: "mimo-v",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return trimmed
    }
}

enum TitleConnectionStatus: Equatable {
    case idle
    case testing
    case connected
    case quotaExhausted
    case http(Int)
    case failed(String)

    var label: LocalizedStringKey? {
        switch self {
        case .idle:
            return nil
        case .testing:
            return "Testing…"
        case .connected:
            return "Connected"
        case .quotaExhausted:
            return "Quota exhausted"
        case .http(let code):
            return "HTTP \(code)"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var isSuccess: Bool {
        self == .connected
    }
}

enum TitleRegenerationStatus: Equatable {
    case idle
    case queued
    case service(String)
    case error

    var label: LocalizedStringKey? {
        switch self {
        case .idle:
            return nil
        case .queued:
            return "Queued…"
        case .service(let status):
            return "Service status: \(status)"
        case .error:
            return "Error"
        }
    }
}

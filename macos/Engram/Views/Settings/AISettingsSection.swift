// macos/Engram/Views/Settings/AISettingsSection.swift
import SwiftUI

struct AISettingsSection: View {
    @Environment(EngramServiceClient.self) var serviceClient

    // Provider
    @State private var aiProtocol: String = "openai"
    @State private var aiBaseURL: String = ""
    @State private var aiApiKey: String = ""
    @State private var aiModel: String = "gpt-4o-mini"

    // NOTE: Embeddings controls (provider/model/dimension) are intentionally
    // omitted from the app Settings UI. The service/MCP runtime does implement
    // embedding + semantic search when configured (ENGRAM_EMBEDDING_* / settings
    // keys + SessionVectorSearchAvailability). App search stays keyword-only.

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

    // Title generation
    @State private var titleProvider: String = "ollama"
    @State private var titleBaseURL: String = ""
    @State private var titleModel: String = "qwen2.5:3b"
    @State private var titleApiKey: String = ""
    @State private var titleTestStatus: TitleConnectionStatus = .idle
    @State private var titleRegenerateStatus: TitleRegenerationStatus = .idle
    @State private var isLoadingSettings = false
    @State private var saveAISettingsTask: Task<Void, Never>? = nil
    @State private var saveTitleSettingsTask: Task<Void, Never>? = nil
    static let settingsSaveDebounceNanoseconds: UInt64 = 400_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "brain", title: "AI Summary")

            // Provider
            GroupBox("Provider") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Protocol", selection: $aiProtocol) {
                        Text("OpenAI Compatible").tag("openai")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: aiProtocol) { scheduleSaveAISettings() }

                    HStack {
                        Text("Base URL")
                        Spacer()
                        TextField("Default", text: $aiBaseURL)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiBaseURL) { scheduleSaveAISettings() }
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
                            .onChange(of: aiApiKey) { scheduleSaveAISettings() }
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        TextField("gpt-4o-mini", text: $aiModel)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiModel) { scheduleSaveAISettings() }
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
                    .onChange(of: summaryLanguage) { scheduleSaveAISettings() }

                    Stepper("Max Sentences: \(summaryMaxSentences)", value: $summaryMaxSentences, in: 1...10)
                        .onChange(of: summaryMaxSentences) { scheduleSaveAISettings() }

                    HStack {
                        Text("Style")
                        Spacer()
                        TextField("Optional, e.g. 技术向", text: $summaryStyle)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: summaryStyle) { scheduleSaveAISettings() }
                    }

                    DisclosureGroup("Custom Prompt", isExpanded: $showCustomPrompt) {
                        TextEditor(text: $summaryPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .onChange(of: summaryPrompt) { scheduleSaveAISettings() }
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
                    .onChange(of: summaryPreset) { scheduleSaveAISettings() }

                    DisclosureGroup("Custom", isExpanded: $showCustomGeneration) {
                        HStack {
                            Text("Max Tokens")
                            Spacer()
                            TextField("200", value: $summaryMaxTokens, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summaryMaxTokens) { scheduleSaveAISettings() }
                        }
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Slider(value: $summaryTemperature, in: 0...1, step: 0.1)
                                .frame(width: 160)
                                .onChange(of: summaryTemperature) { scheduleSaveAISettings() }
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
                                .onChange(of: summarySampleFirst) { scheduleSaveAISettings() }
                            Text("messages")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Sample Last")
                            Spacer()
                            TextField("30", value: $summarySampleLast, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summarySampleLast) { scheduleSaveAISettings() }
                            Text("messages")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Truncate")
                            Spacer()
                            TextField("500", value: $summaryTruncateChars, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: summaryTruncateChars) { scheduleSaveAISettings() }
                            Text("chars/msg")
                                .foregroundStyle(.secondary)
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
                    .onChange(of: titleProvider) { scheduleSaveTitleSettings() }

                    HStack {
                        Text("URL")
                        Spacer()
                        TextField(titleProvider == "ollama" ? "http://localhost:11434" : "Base URL", text: $titleBaseURL)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: titleBaseURL) { scheduleSaveTitleSettings() }
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        TextField("qwen2.5:3b", text: $titleModel)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: titleModel) { scheduleSaveTitleSettings() }
                    }

                    if titleProvider != "ollama" {
                        HStack {
                            Text("API Key")
                            Spacer()
                            SecureField("Required", text: $titleApiKey)
                                .frame(width: 260)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: titleApiKey) { scheduleSaveTitleSettings() }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Test Connection") {
                            titleTestStatus = .testing
                            let url = titleBaseURL.isEmpty ? "http://localhost:11434" : titleBaseURL
                            let testURL = titleProvider == "ollama"
                                ? "\(url)/api/tags"
                                : appendAPIPath("/v1/chat/completions", to: url)
                            Task {
                                do {
                                    // M20: free-text Base URL must not force-unwrap.
                                    guard let parsed = URL(string: testURL),
                                          parsed.scheme != nil,
                                          parsed.host != nil else {
                                        titleTestStatus = .failed("Invalid URL")
                                        return
                                    }
                                    var req = URLRequest(url: parsed)
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
                                    titleRegenerateStatus = .service(response.status, response.total)
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
        "Default: https://api.openai.com"
    }

    private func refreshRuntimeAISecrets() {
        EngramServiceLauncher.writeRuntimeAISecrets(
            toPath: EngramServiceLauncher.runtimeAISecretsPath(
                forSocketPath: UnixSocketEngramServiceTransport.defaultSocketPath()
            ),
            keychainReader: KeychainHelper.get
        )
    }

    /// Debounce settings.json writes while typing (M21 partial; MainActor residual).
    private func scheduleSaveAISettings() {
        saveAISettingsTask?.cancel()
        saveAISettingsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.settingsSaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            saveAISettings()
        }
    }

    private func scheduleSaveTitleSettings() {
        saveTitleSettingsTask?.cancel()
        saveTitleSettingsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.settingsSaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            saveTitleSettings()
        }
    }

    private func saveAISettings() {
        guard !isLoadingSettings else { return }
        // SEC-M3: Keychain first. DEBUG/DerivedData may fall back to plaintext
        // via KeychainHelper.shouldBypassKeychain; Release never writes secrets
        // into settings.json when Keychain save fails.
        if !aiApiKey.isEmpty {
            let saved = KeychainHelper.set("aiApiKey", value: aiApiKey)
            if saved {
                mutateEngramSettings { $0["aiApiKey"] = "@keychain" }
            } else if KeychainHelper.allowsPlaintextSettingsFallback {
                mutateEngramSettings { $0["aiApiKey"] = aiApiKey }
            } else {
                // Fail closed: keep previous settings marker if any; do not persist
                // the secret in plaintext JSON.
                mutateEngramSettings { $0["aiApiKey"] = "@keychain" }
            }
        } else {
            KeychainHelper.delete("aiApiKey")
            mutateEngramSettings { $0.removeValue(forKey: "aiApiKey") }
        }
        refreshRuntimeAISecrets()
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

        }
    }

    private func deleteTitleAPIKey() {
        KeychainHelper.delete("titleApiKey")
        mutateEngramSettings { $0.removeValue(forKey: "titleApiKey") }
    }

    private func saveTitleSettings() {
        guard !isLoadingSettings else { return }
        switch TitleAPIKeyPersistenceAction.decide(provider: titleProvider, apiKey: titleApiKey) {
        case .write(let titleApiKey):
            let saved = KeychainHelper.set("titleApiKey", value: titleApiKey)
            if saved {
                mutateEngramSettings { $0["titleApiKey"] = "@keychain" }
            } else if KeychainHelper.allowsPlaintextSettingsFallback {
                mutateEngramSettings { $0["titleApiKey"] = titleApiKey }
            } else {
                mutateEngramSettings { $0["titleApiKey"] = "@keychain" }
            }
        case .deleteExisting:
            deleteTitleAPIKey()
        case .preserveExisting:
            break
        }
        refreshRuntimeAISecrets()
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
        }
    }

    private func loadAISettings() {
        guard let settings = readEngramSettings() else { return }
        isLoadingSettings = true
        defer { clearLoadingSettingsAfterViewUpdate() }

        if let v = settings["aiProtocol"] as? String {
            aiProtocol = v == "openai" ? v : "openai"
        }
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

        if let v = settings["titleProvider"] as? String { titleProvider = v }
        if let v = settings["titleBaseUrl"] as? String { titleBaseURL = v }
        else if let v = settings["titleBaseURL"] as? String { titleBaseURL = v }
        if let v = settings["titleModel"] as? String { titleModel = normalizeOpenAICompatibleModel(v, baseURL: titleBaseURL) }
        titleApiKey = KeychainHelper.get("titleApiKey")
            ?? { let v = settings["titleApiKey"] as? String; return v == "@keychain" ? nil : v }() ?? ""
    }

    private func clearLoadingSettingsAfterViewUpdate() {
        Task { @MainActor in
            await Task.yield()
            isLoadingSettings = false
        }
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

enum TitleAPIKeyPersistenceAction: Equatable {
    case write(String)
    case deleteExisting
    case preserveExisting

    static func decide(provider: String, apiKey: String) -> TitleAPIKeyPersistenceAction {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProvider == "ollama" {
            return .preserveExisting
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? .deleteExisting : .write(trimmedKey)
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
    case service(String, Int?)
    case error

    var label: LocalizedStringKey? {
        switch self {
        case .idle:
            return nil
        case .queued:
            return "Queued…"
        case .service:
            // The service runs regeneration fire-and-forget (os_log only, no
            // progress channel) and always returns total:nil, so don't promise a
            // count the service never sends. Report honestly that it is running
            // in the background instead of freezing on the raw "started" status.
            return "Regenerating in background — titles update as they finish"
        case .error:
            return "Error"
        }
    }
}

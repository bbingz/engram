// macos/Engram/Views/Settings/AISettingsSection.swift
import SwiftUI

struct AISettingsSection: View {
    let serviceSocketPath: String
    @Environment(\.engramServiceClient) var serviceClient

    init(serviceSocketPath: String) {
        self.serviceSocketPath = serviceSocketPath
    }

    // Provider
    @State private var aiProtocol: String = "openai"
    @State private var aiBaseURL: String = ""
    @State private var aiApiKey: String = ""
    @State private var aiAPIKeyWasEdited = false
    @State private var preserveEmptyAIAPIKey = false
    @State private var aiAPIKeyPersistenceResult: APIKeyPersistenceResult? = nil
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
    @State private var titleAPIKeyWasEdited = false
    @State private var preserveEmptyTitleAPIKey = false
    @State private var titleAPIKeyPersistenceResult: APIKeyPersistenceResult? = nil
    @State private var titleTestStatus: TitleConnectionStatus = .idle
    @State private var titleRegenerateStatus: TitleRegenerationStatus = .idle
    @State private var isLoadingSettings = false
    @State private var settingsLoadApplied = false
    @State private var settingsLoadGeneration = 0
    @State private var saveAISettingsTask: Task<Void, Never>? = nil
    @State private var saveTitleSettingsTask: Task<Void, Never>? = nil
    @FocusState private var aiAPIKeyFocused: Bool
    @FocusState private var titleAPIKeyFocused: Bool
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
                            .focused($aiAPIKeyFocused)
                            .onChange(of: aiApiKey) {
                                guard settingsLoadApplied else { return }
                                aiAPIKeyWasEdited = true
                                preserveEmptyAIAPIKey = false
                                scheduleSaveAISettings()
                            }
                            .onChange(of: aiAPIKeyFocused) {
                                if !aiAPIKeyFocused { scheduleSaveAISettings() }
                            }
                            .disabled(!settingsLoadApplied)
                        Button("Clear") {
                            aiApiKey = ""
                            aiAPIKeyWasEdited = true
                            preserveEmptyAIAPIKey = false
                            saveAISettings(commitFocusedEmpty: true)
                        }
                        .disabled(!settingsLoadApplied)
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        TextField("gpt-4o-mini", text: $aiModel)
                            .frame(width: 260)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: aiModel) { scheduleSaveAISettings() }
                    }

                    Text(apiKeyStorageMessage(
                        result: aiAPIKeyPersistenceResult,
                        preservingUnavailableKey: preserveEmptyAIAPIKey
                    ))
                        .font(.caption2)
                        .foregroundStyle(apiKeyStorageColor(
                            result: aiAPIKeyPersistenceResult,
                            preservingUnavailableKey: preserveEmptyAIAPIKey
                        ))
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
                                .focused($titleAPIKeyFocused)
                                .onChange(of: titleApiKey) {
                                    guard settingsLoadApplied else { return }
                                    titleAPIKeyWasEdited = true
                                    preserveEmptyTitleAPIKey = false
                                    scheduleSaveTitleSettings()
                                }
                                .onChange(of: titleAPIKeyFocused) {
                                    if !titleAPIKeyFocused { scheduleSaveTitleSettings() }
                                }
                                .disabled(!settingsLoadApplied)
                            Button("Clear") {
                                titleApiKey = ""
                                titleAPIKeyWasEdited = true
                                preserveEmptyTitleAPIKey = false
                                saveTitleSettings(commitFocusedEmpty: true)
                            }
                            .disabled(!settingsLoadApplied)
                        }
                        Text(apiKeyStorageMessage(
                            result: titleAPIKeyPersistenceResult,
                            preservingUnavailableKey: preserveEmptyTitleAPIKey
                        ))
                        .font(.caption2)
                        .foregroundStyle(apiKeyStorageColor(
                            result: titleAPIKeyPersistenceResult,
                            preservingUnavailableKey: preserveEmptyTitleAPIKey
                        ))
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
                                    // M20: free-text Base URL via pure helper (unit-tested).
                                    guard let parsed = AISettingsURLValidation.parseConnectionURL(testURL) else {
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
        .task { await loadAISettings() }
        // R9/M21 residual: cancel-on-retype alone dropped the last keystrokes when the
        // section disappeared before the 400ms timer fired. Flush any pending debounce
        // immediately on leave so model/baseURL/API-key edits are not lost.
        .onDisappear { flushPendingAISettingsSaves() }
    }

    // MARK: - Helpers

    private func defaultBaseURL(for proto: String) -> String {
        "Default: https://api.openai.com"
    }

    /// Debounce settings.json writes while typing (M21). The timer stays on
    /// MainActor so it can read `@State`; persist is off-main (R9).
    private func scheduleSaveAISettings() {
        guard !isLoadingSettings else { return }
        saveAISettingsTask?.cancel()
        saveAISettingsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.settingsSaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            saveAISettingsTask = nil
            saveAISettings()
        }
    }

    private func scheduleSaveTitleSettings() {
        guard !isLoadingSettings else { return }
        saveTitleSettingsTask?.cancel()
        saveTitleSettingsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.settingsSaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            saveTitleSettingsTask = nil
            saveTitleSettings()
        }
    }

    /// Flush any in-flight debounce timers before the section leaves the tree.
    private func flushPendingAISettingsSaves() {
        let flushAI = AISettingsSaveFlush.shouldFlush(
            pendingTask: saveAISettingsTask != nil,
            isLoadingSettings: isLoadingSettings
        )
        let flushTitle = AISettingsSaveFlush.shouldFlush(
            pendingTask: saveTitleSettingsTask != nil,
            isLoadingSettings: isLoadingSettings
        )
        saveAISettingsTask?.cancel()
        saveTitleSettingsTask?.cancel()
        saveAISettingsTask = nil
        saveTitleSettingsTask = nil
        if flushAI {
            saveAISettings(commitFocusedEmpty: false)
        }
        if flushTitle {
            saveTitleSettings(commitFocusedEmpty: false)
        }
        Task { @MainActor in
            await AISettingsPersister.waitForPendingPersistence()
        }
    }

    /// Snapshot `@State` on MainActor, then persist off-main so debounce/flush
    /// never flocks settings.json or talks to Keychain on the UI thread (R9).
    private func saveAISettings(commitFocusedEmpty: Bool = false) {
        guard !isLoadingSettings else { return }
        let applyAPIKey = aiAPIKeyWasEdited
        let submittedAPIKey = aiApiKey
        AISettingsPersister.persistAIOffMain(
            AISettingsPersistSnapshot(
                apiKey: submittedAPIKey,
                preserveEmptyAPIKey: preserveEmptyAIAPIKey
                    || !aiAPIKeyWasEdited
                    || APIKeyFocusedEmptyPolicy.shouldPreserve(
                        value: aiApiKey,
                        isFocused: aiAPIKeyFocused,
                        commitFocusedEmpty: commitFocusedEmpty
                    ),
                applyAPIKey: applyAPIKey,
                aiProtocol: aiProtocol,
                aiBaseURL: aiBaseURL,
                aiModel: aiModel,
                summaryLanguage: summaryLanguage,
                summaryMaxSentences: summaryMaxSentences,
                summaryStyle: summaryStyle,
                summaryPrompt: summaryPrompt,
                summaryPreset: summaryPreset,
                summaryMaxTokens: summaryMaxTokens,
                summaryTemperature: summaryTemperature,
                summarySampleFirst: summarySampleFirst,
                summarySampleLast: summarySampleLast,
                summaryTruncateChars: summaryTruncateChars
            ),
            serviceSocketPath: serviceSocketPath,
            onAPIKeyResult: { result in
                guard applyAPIKey, result.isRealKeyApply else { return }
                aiAPIKeyPersistenceResult = result
                if APIKeyEditCompletion.shouldClearEdited(
                    result: result,
                    submittedValue: submittedAPIKey,
                    currentValue: self.aiApiKey
                ) {
                    aiAPIKeyWasEdited = false
                }
            }
        )
    }

    private func saveTitleSettings(commitFocusedEmpty: Bool = false) {
        guard !isLoadingSettings else { return }
        let applyAPIKey = titleAPIKeyWasEdited
        let submittedAPIKey = titleApiKey
        AISettingsPersister.persistTitleOffMain(
            TitleSettingsPersistSnapshot(
                provider: titleProvider,
                apiKey: submittedAPIKey,
                preserveEmptyAPIKey: preserveEmptyTitleAPIKey
                    || !titleAPIKeyWasEdited
                    || APIKeyFocusedEmptyPolicy.shouldPreserve(
                        value: titleApiKey,
                        isFocused: titleAPIKeyFocused,
                        commitFocusedEmpty: commitFocusedEmpty
                    ),
                applyAPIKey: applyAPIKey,
                baseURL: titleBaseURL,
                model: titleModel
            ),
            serviceSocketPath: serviceSocketPath,
            onAPIKeyResult: { result in
                guard applyAPIKey, result.isRealKeyApply else { return }
                titleAPIKeyPersistenceResult = result
                if APIKeyEditCompletion.shouldClearEdited(
                    result: result,
                    submittedValue: submittedAPIKey,
                    currentValue: self.titleApiKey
                ) {
                    titleAPIKeyWasEdited = false
                }
            }
        )
    }

    private func loadAISettings() async {
        settingsLoadGeneration += 1
        let generation = settingsLoadGeneration
        isLoadingSettings = true
        settingsLoadApplied = false
        defer { clearLoadingSettingsAfterViewUpdate(generation: generation) }
        let loaded = await AISettingsLoader.loadOffMain()
        guard !Task.isCancelled, generation == settingsLoadGeneration else { return }
        let settings = loaded.settingsData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]

        let loadedAIKey = APIKeyLoadedState.resolve(
            keychainValue: loaded.aiAPIKey,
            storedValue: settings["aiApiKey"] as? String
        )
        aiApiKey = loadedAIKey.value
        preserveEmptyAIAPIKey = loadedAIKey.preserveEmptyValue
        aiAPIKeyPersistenceResult = loadedAIKey.persistenceResult
        aiAPIKeyWasEdited = false

        let loadedTitleKey = APIKeyLoadedState.resolve(
            keychainValue: loaded.titleAPIKey,
            storedValue: settings["titleApiKey"] as? String
        )
        titleApiKey = loadedTitleKey.value
        preserveEmptyTitleAPIKey = loadedTitleKey.preserveEmptyValue
        titleAPIKeyPersistenceResult = loadedTitleKey.persistenceResult
        titleAPIKeyWasEdited = false

        if let v = settings["aiProtocol"] as? String {
            aiProtocol = v == "openai" ? v : "openai"
        }
        if let v = settings["aiBaseURL"] as? String { aiBaseURL = v }
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
    }

    private func clearLoadingSettingsAfterViewUpdate(generation: Int) {
        Task { @MainActor in
            await Task.yield()
            guard generation == settingsLoadGeneration else { return }
            isLoadingSettings = false
            settingsLoadApplied = true
        }
    }

    private func apiKeyStorageMessage(
        result: APIKeyPersistenceResult?,
        preservingUnavailableKey: Bool
    ) -> String {
        if preservingUnavailableKey {
            return "Existing Keychain key is preserved but unavailable in this build"
        }
        return result?.message ?? "API keys are stored in macOS Keychain"
    }

    private func apiKeyStorageColor(
        result: APIKeyPersistenceResult?,
        preservingUnavailableKey: Bool
    ) -> Color {
        if preservingUnavailableKey { return .orange }
        switch result {
        case .plaintext: return .orange
        case .savedMarkerFailed, .runtimeBridgeRefreshFailed, .failed: return .red
        case .saved, .cleared, .unchanged, .none: return .secondary
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
        normalizeOpenAICompatibleModelName(model, baseURL: baseURL)
    }
}

fileprivate func normalizeOpenAICompatibleModelName(_ model: String, baseURL: String) -> String {
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

struct AISettingsPersistSnapshot: Sendable, Equatable {
    var apiKey: String
    var preserveEmptyAPIKey: Bool
    var applyAPIKey: Bool
    var aiProtocol: String
    var aiBaseURL: String
    var aiModel: String
    var summaryLanguage: String
    var summaryMaxSentences: Int
    var summaryStyle: String
    var summaryPrompt: String
    var summaryPreset: String
    var summaryMaxTokens: Int
    var summaryTemperature: Double
    var summarySampleFirst: Int
    var summarySampleLast: Int
    var summaryTruncateChars: Int
}

struct TitleSettingsPersistSnapshot: Sendable, Equatable {
    var provider: String
    var apiKey: String
    var preserveEmptyAPIKey: Bool
    var applyAPIKey: Bool
    var baseURL: String
    var model: String
}

struct AISettingsPersistenceHooks: Sendable {
    let beforeMailbox: @Sendable (AISettingsPersistSnapshot) async -> Void
    let persist: @Sendable (AISettingsPersistSnapshot) -> APIKeyPersistenceResult
}

struct TitleSettingsPersistenceHooks: Sendable {
    let beforeMailbox: @Sendable (TitleSettingsPersistSnapshot) async -> Void
    let persist: @Sendable (TitleSettingsPersistSnapshot) -> APIKeyPersistenceResult
}

enum AISettingsLoader {
    struct Loaded: Sendable {
        let settingsData: Data?
        let aiAPIKey: String?
        let titleAPIKey: String?
    }

    static func loadOffMain() async -> Loaded {
        await AISettingsPersister.waitForPendingPersistence()
        return await Task.detached(priority: .userInitiated) {
            Loaded(
                settingsData: readEngramSettingsData(),
                aiAPIKey: KeychainHelper.get("aiApiKey"),
                titleAPIKey: KeychainHelper.get("titleApiKey")
            )
        }.value
    }
}

struct APIKeyLoadedState: Equatable {
    let value: String
    let preserveEmptyValue: Bool
    let persistenceResult: APIKeyPersistenceResult?

    static func resolve(keychainValue: String?, storedValue: String?) -> APIKeyLoadedState {
        if let keychainValue {
            return APIKeyLoadedState(
                value: keychainValue,
                preserveEmptyValue: false,
                persistenceResult: .saved
            )
        }
        if storedValue == "@keychain" {
            return APIKeyLoadedState(value: "", preserveEmptyValue: true, persistenceResult: nil)
        }
        if let storedValue, !storedValue.isEmpty {
            return APIKeyLoadedState(
                value: storedValue,
                preserveEmptyValue: false,
                persistenceResult: .plaintext
            )
        }
        return APIKeyLoadedState(value: "", preserveEmptyValue: true, persistenceResult: nil)
    }
}

/// R9: Keychain + settings.json + runtime-secrets I/O runs off MainActor.
enum AISettingsPersister {
    private static let mailbox = Mailbox()
    @MainActor private static var aiPersistenceTail: Task<Void, Never>?
    @MainActor private static var titlePersistenceTail: Task<Void, Never>?

    @MainActor
    static func waitForPendingPersistence() async {
        let aiTail = aiPersistenceTail
        let titleTail = titlePersistenceTail
        await aiTail?.value
        await titleTail?.value
    }

    @MainActor
    static func persistAIOffMain(
        _ snapshot: AISettingsPersistSnapshot,
        serviceSocketPath: String,
        testHooks: AISettingsPersistenceHooks? = nil,
        onAPIKeyResult: @escaping @MainActor @Sendable (APIKeyPersistenceResult) -> Void
    ) {
        let previous = aiPersistenceTail
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            if let testHooks {
                await testHooks.beforeMailbox(snapshot)
            }
            let result = await mailbox.persistAI(
                snapshot,
                serviceSocketPath: serviceSocketPath,
                override: testHooks?.persist
            )
            await onAPIKeyResult(result)
        }
        aiPersistenceTail = task
    }

    @MainActor
    static func persistTitleOffMain(
        _ snapshot: TitleSettingsPersistSnapshot,
        serviceSocketPath: String,
        testHooks: TitleSettingsPersistenceHooks? = nil,
        onAPIKeyResult: @escaping @MainActor @Sendable (APIKeyPersistenceResult) -> Void
    ) {
        let previous = titlePersistenceTail
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            if let testHooks {
                await testHooks.beforeMailbox(snapshot)
            }
            let result = await mailbox.persistTitle(
                snapshot,
                serviceSocketPath: serviceSocketPath,
                override: testHooks?.persist
            )
            await onAPIKeyResult(result)
        }
        titlePersistenceTail = task
    }

    actor Mailbox {
        private var aiSnapshotBlockedByFailedApply = false
        private var titleSnapshotBlockedByFailedApply = false

        func persistAI(
            _ snapshot: AISettingsPersistSnapshot,
            serviceSocketPath: String,
            override: (@Sendable (AISettingsPersistSnapshot) -> APIKeyPersistenceResult)? = nil
        ) -> APIKeyPersistenceResult {
            if let override { return override(snapshot) }
            let action = APIKeyEditAction.decide(
                apiKey: snapshot.apiKey,
                preserveEmptyAPIKey: snapshot.preserveEmptyAPIKey,
                applyAPIKey: snapshot.applyAPIKey
            )
            var result: APIKeyPersistenceResult
            switch action {
            case .write(let apiKey):
                result = applyAPIKey(
                    account: "aiApiKey",
                    settingsKey: "aiApiKey",
                    value: apiKey,
                    preserveEmptyValue: false
                )
            case .deleteExisting:
                result = applyAPIKey(
                    account: "aiApiKey",
                    settingsKey: "aiApiKey",
                    value: "",
                    preserveEmptyValue: false
                )
            case .preserveExisting:
                result = .unchanged
            }
            result = result.reconcilingRuntimeBridgeRefresh {
                refreshRuntimeAISecrets(serviceSocketPath: serviceSocketPath)
            }
            let wasBlocked = aiSnapshotBlockedByFailedApply
            aiSnapshotBlockedByFailedApply = APIKeySnapshotPersistenceGate.nextBlockedState(
                wasBlockedByFailedApply: wasBlocked,
                action: action,
                result: result
            )
            guard APIKeySnapshotPersistenceGate.permitsSnapshot(
                wasBlockedByFailedApply: wasBlocked,
                action: action,
                result: result
            ) else { return result }
            mutateEngramSettings { settings in
                settings["aiProtocol"] = snapshot.aiProtocol
                if !snapshot.aiBaseURL.isEmpty {
                    settings["aiBaseURL"] = snapshot.aiBaseURL
                } else {
                    settings.removeValue(forKey: "aiBaseURL")
                }
                settings["aiModel"] = normalizeOpenAICompatibleModelName(
                    snapshot.aiModel,
                    baseURL: snapshot.aiBaseURL
                )
                settings["summaryLanguage"] = snapshot.summaryLanguage
                settings["summaryMaxSentences"] = snapshot.summaryMaxSentences
                if !snapshot.summaryStyle.isEmpty {
                    settings["summaryStyle"] = snapshot.summaryStyle
                } else {
                    settings.removeValue(forKey: "summaryStyle")
                }
                if !snapshot.summaryPrompt.isEmpty {
                    settings["summaryPrompt"] = snapshot.summaryPrompt
                } else {
                    settings.removeValue(forKey: "summaryPrompt")
                }
                settings["summaryPreset"] = snapshot.summaryPreset
                AIGenerationSettings(
                    maxTokens: snapshot.summaryMaxTokens,
                    temperature: snapshot.summaryTemperature,
                    sampleFirst: snapshot.summarySampleFirst,
                    sampleLast: snapshot.summarySampleLast,
                    truncateChars: snapshot.summaryTruncateChars
                ).write(into: &settings)
            }
            return result
        }

        func persistTitle(
            _ snapshot: TitleSettingsPersistSnapshot,
            serviceSocketPath: String,
            override: (@Sendable (TitleSettingsPersistSnapshot) -> APIKeyPersistenceResult)? = nil
        ) -> APIKeyPersistenceResult {
            if let override { return override(snapshot) }
            let titleAction = TitleAPIKeyPersistenceAction.decide(
                provider: snapshot.provider,
                apiKey: snapshot.apiKey,
                preserveEmptyAPIKey: snapshot.preserveEmptyAPIKey,
                applyAPIKey: snapshot.applyAPIKey
            )
            let action: APIKeyEditAction
            var result: APIKeyPersistenceResult
            switch titleAction {
            case .write(let titleApiKey):
                action = .write(titleApiKey)
                result = applyAPIKey(
                    account: "titleApiKey",
                    settingsKey: "titleApiKey",
                    value: titleApiKey,
                    preserveEmptyValue: snapshot.preserveEmptyAPIKey
                )
            case .deleteExisting:
                action = .deleteExisting
                result = applyAPIKey(
                    account: "titleApiKey",
                    settingsKey: "titleApiKey",
                    value: "",
                    preserveEmptyValue: false
                )
            case .preserveExisting:
                action = .preserveExisting
                result = .unchanged
            }
            result = result.reconcilingRuntimeBridgeRefresh {
                refreshRuntimeAISecrets(serviceSocketPath: serviceSocketPath)
            }
            let wasBlocked = titleSnapshotBlockedByFailedApply
            titleSnapshotBlockedByFailedApply = APIKeySnapshotPersistenceGate.nextBlockedState(
                wasBlockedByFailedApply: wasBlocked,
                action: action,
                result: result
            )
            guard APIKeySnapshotPersistenceGate.permitsSnapshot(
                wasBlockedByFailedApply: wasBlocked,
                action: action,
                result: result
            ) else { return result }
            mutateEngramSettings { settings in
                settings["titleProvider"] = snapshot.provider
                if !snapshot.baseURL.isEmpty {
                    settings["titleBaseUrl"] = snapshot.baseURL
                    settings.removeValue(forKey: "titleBaseURL")
                } else {
                    settings.removeValue(forKey: "titleBaseUrl")
                    settings.removeValue(forKey: "titleBaseURL")
                }
                settings["titleModel"] = normalizeOpenAICompatibleModelName(
                    snapshot.model,
                    baseURL: snapshot.baseURL
                )
            }
            return result
        }

        /// SEC-M3: Keychain first. Only DEBUG may fall back to plaintext.
        private func applyAPIKey(
            account: String,
            settingsKey: String,
            value: String,
            preserveEmptyValue: Bool
        ) -> APIKeyPersistenceResult {
            APIKeyPersistencePolicy.apply(
                settingsKey: settingsKey,
                value: value,
                preserveEmptyValue: preserveEmptyValue,
                saveToKeychain: { KeychainHelper.set(account, value: $0) },
                deleteFromKeychain: { KeychainHelper.delete(account) },
                keychainReader: { KeychainHelper.get(account) },
                allowsPlaintextFallback: KeychainHelper.allowsPlaintextSettingsFallback,
                probeSettings: { probeEngramSettingsForMutation() },
                mutateSettings: { transform in
                    mutateEngramSettings { settings in transform(&settings) }
                }
            )
        }

        private func refreshRuntimeAISecrets(serviceSocketPath: String) -> Bool {
            EngramServiceLauncher.refreshRuntimeAISecrets(
                toPath: EngramServiceLauncher.runtimeAISecretsPath(
                    forSocketPath: serviceSocketPath
                ),
                keychainReader: KeychainHelper.get
            )
        }
    }
}

enum APIKeyPersistenceResult: Sendable, Equatable {
    case saved
    case savedMarkerFailed
    case cleared
    case runtimeBridgeRefreshFailed
    case plaintext
    case unchanged
    case failed

    var changedKeychain: Bool {
        self == .saved
            || self == .savedMarkerFailed
            || self == .cleared
            || self == .runtimeBridgeRefreshFailed
    }

    var isRealKeyApply: Bool {
        self != .unchanged
    }

    var permitsSettingsSnapshotPersistence: Bool {
        self != .failed && self != .savedMarkerFailed
    }

    var message: String {
        switch self {
        case .saved: return "API key is stored in macOS Keychain"
        case .savedMarkerFailed: return "API key is stored in Keychain, but settings.json could not be updated"
        case .cleared: return "API key was removed from macOS Keychain"
        case .runtimeBridgeRefreshFailed:
            return "API key changed in Keychain, but the service credential bridge could not be refreshed"
        case .plaintext: return "DEBUG only: API key is stored in plaintext in ~/.engram/settings.json"
        case .unchanged: return "Existing API key was preserved"
        case .failed: return "Could not store API key in macOS Keychain"
        }
    }

    func reconcilingRuntimeBridgeRefresh(
        _ refresh: () -> Bool
    ) -> APIKeyPersistenceResult {
        guard changedKeychain else { return self }
        let refreshed = refresh()
        guard self != .savedMarkerFailed else { return self }
        return refreshed ? self : .runtimeBridgeRefreshFailed
    }
}

enum APIKeyPersistencePolicy {
    static func apply(
        settingsKey: String,
        value: String,
        preserveEmptyValue: Bool,
        saveToKeychain: (String) -> Bool,
        deleteFromKeychain: () -> Void,
        keychainReader: () -> String? = { nil },
        allowsPlaintextFallback: Bool,
        probeSettings: () -> Bool = { true },
        mutateSettings: (((inout [String: Any]) -> Void) -> Bool)
    ) -> APIKeyPersistenceResult {
        if value.isEmpty {
            guard !preserveEmptyValue else { return .unchanged }
            guard mutateSettings({ $0.removeValue(forKey: settingsKey) }) else {
                return .failed
            }
            deleteFromKeychain()
            guard keychainReader() == nil else {
                _ = mutateSettings { $0[settingsKey] = "@keychain" }
                return .failed
            }
            return .cleared
        }
        if allowsPlaintextFallback {
            guard mutateSettings({ $0[settingsKey] = value }) else { return .failed }
            guard saveToKeychain(value) else { return .plaintext }
            if mutateSettings({ $0[settingsKey] = "@keychain" }) { return .saved }
            return mutateSettings({ $0[settingsKey] = "@keychain" }) ? .saved : .plaintext
        }
        // Probe without a no-op write: a missing settings file must not be
        // materialized before Keychain accepts the replacement credential.
        guard probeSettings() else { return .failed }
        guard saveToKeychain(value) else { return .failed }
        if mutateSettings({ $0[settingsKey] = "@keychain" }) { return .saved }
        return mutateSettings({ $0[settingsKey] = "@keychain" }) ? .saved : .savedMarkerFailed
    }
}

enum APIKeySnapshotPersistenceGate {
    static func permitsSnapshot(
        wasBlockedByFailedApply: Bool,
        action: APIKeyEditAction,
        result: APIKeyPersistenceResult
    ) -> Bool {
        guard result.permitsSettingsSnapshotPersistence else { return false }
        guard wasBlockedByFailedApply else { return true }
        switch action {
        case .write, .deleteExisting:
            return result == .saved
                || result == .cleared
                || result == .runtimeBridgeRefreshFailed
                || result == .plaintext
        case .preserveExisting:
            return false
        }
    }

    static func nextBlockedState(
        wasBlockedByFailedApply: Bool,
        action: APIKeyEditAction,
        result: APIKeyPersistenceResult
    ) -> Bool {
        if result == .failed || result == .savedMarkerFailed { return true }
        switch action {
        case .write, .deleteExisting:
            return !(result == .saved
                || result == .cleared
                || result == .runtimeBridgeRefreshFailed
                || result == .plaintext)
        case .preserveExisting:
            return wasBlockedByFailedApply
        }
    }
}

enum APIKeyEditCompletion {
    static func shouldClearEdited(
        result: APIKeyPersistenceResult,
        submittedValue: String,
        currentValue: String
    ) -> Bool {
        guard submittedValue == currentValue else { return false }
        switch result {
        case .saved, .cleared, .plaintext:
            return true
        case .savedMarkerFailed, .runtimeBridgeRefreshFailed, .unchanged, .failed:
            return false
        }
    }
}

/// M20: pure URL parse for free-text Test Connection fields.
enum AISettingsURLValidation {
    /// Accept only absolute URLs with non-empty scheme and host (rejects
    /// leading-space garbage and `URL(string:)` force-unwrap crash fodder).
    static func parseConnectionURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme, !scheme.isEmpty,
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}

/// R9/M21: decide whether leaving the AI settings section must flush a pending
/// debounce timer. Pure so the leave-flush gate is unit-testable without SwiftUI
/// host plumbing. The flush still snapshots on MainActor and persists off-main.
enum AISettingsSaveFlush {
    static func shouldFlush(pendingTask: Bool, isLoadingSettings: Bool) -> Bool {
        pendingTask && !isLoadingSettings
    }
}

enum APIKeyFocusedEmptyPolicy {
    static func shouldPreserve(
        value: String,
        isFocused: Bool,
        commitFocusedEmpty: Bool
    ) -> Bool {
        _ = isFocused
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !commitFocusedEmpty
    }
}

enum APIKeyEditAction: Equatable {
    case write(String)
    case deleteExisting
    case preserveExisting

    static func decide(
        apiKey: String,
        preserveEmptyAPIKey: Bool,
        applyAPIKey: Bool = true
    ) -> APIKeyEditAction {
        guard applyAPIKey else { return .preserveExisting }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            return preserveEmptyAPIKey ? .preserveExisting : .deleteExisting
        }
        return .write(trimmedKey)
    }
}

enum TitleAPIKeyPersistenceAction: Equatable {
    case write(String)
    case deleteExisting
    case preserveExisting

    static func decide(
        provider: String,
        apiKey: String,
        preserveEmptyAPIKey: Bool = false,
        applyAPIKey: Bool = true
    ) -> TitleAPIKeyPersistenceAction {
        guard applyAPIKey else { return .preserveExisting }
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProvider == "ollama" {
            return .preserveExisting
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty, preserveEmptyAPIKey {
            return .preserveExisting
        }
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

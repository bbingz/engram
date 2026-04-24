import Foundation

struct AdapterRegistry {
    private var adaptersBySource: [SourceName: any SessionAdapter]

    init(adapters: [any SessionAdapter] = []) {
        adaptersBySource = Dictionary(uniqueKeysWithValues: adapters.map { ($0.source, $0) })
    }

    var sources: [SourceName] {
        adaptersBySource.keys.sorted { $0.rawValue < $1.rawValue }
    }

    func adapter(for source: SourceName) -> (any SessionAdapter)? {
        adaptersBySource[source]
    }
}

struct AdapterGolden: Decodable, Sendable {
    var source: SourceName
    var inputPath: String
    var locator: String
    var sessionInfo: NormalizedSessionInfo?
    var messages: [NormalizedMessage]?
    var toolCalls: [NormalizedToolCall]?
    var usageTotals: TokenUsage?
    var failure: ParserFailure?
}

struct AdapterParityResult: Equatable, Sendable {
    var source: SourceName
    var locator: String
    var listedLocators: [String]
    var sessionInfo: NormalizedSessionInfo?
    var messages: [NormalizedMessage]
    var toolCalls: [NormalizedToolCall]
    var usageTotals: TokenUsage
    var failure: ParserFailure?
}

struct AdapterParityHarness {
    var fixtureRoot: URL
    var registry: AdapterRegistry
    var enabledSources: Set<SourceName>

    init(
        fixtureRoot: URL,
        registry: AdapterRegistry,
        enabledSources: Set<SourceName>
    ) {
        self.fixtureRoot = fixtureRoot
        self.registry = registry
        self.enabledSources = enabledSources
    }

    func loadGoldens() throws -> [AdapterGolden] {
        let decoder = JSONDecoder()
        let urls = try FileManager.default.contentsOfDirectory(
            at: fixtureRoot,
            includingPropertiesForKeys: nil
        )
        var goldens: [AdapterGolden] = []
        for sourceURL in urls where sourceURL.hasDirectoryPath {
            let expected = sourceURL.appendingPathComponent("success.expected.json")
            guard FileManager.default.fileExists(atPath: expected.path) else { continue }
            let data = try Data(contentsOf: expected)
            goldens.append(try decoder.decode(AdapterGolden.self, from: data))
        }
        return goldens.sorted { $0.source.rawValue < $1.source.rawValue }
    }

    func run() async throws -> [AdapterParityResult] {
        var results: [AdapterParityResult] = []
        for golden in try loadGoldens().filter({ enabledSources.contains($0.source) }) {
            guard let adapter = registry.adapter(for: golden.source) else { continue }
            let locator = resolveLocator(golden.locator)
            let listedLocators = try await adapter.listSessionLocators()
            var sessionInfo: NormalizedSessionInfo?
            var failure: ParserFailure?

            switch try await adapter.parseSessionInfo(locator: locator) {
            case .success(let info):
                sessionInfo = info
            case .failure(let parserFailure):
                failure = parserFailure
            }

            var messages: [NormalizedMessage] = []
            if failure == nil {
                let stream = try await adapter.streamMessages(
                    locator: locator,
                    options: StreamMessagesOptions()
                )
                for try await message in stream {
                    messages.append(message)
                }
            }

            let toolCalls = messages.flatMap { $0.toolCalls ?? [] }
            results.append(
                AdapterParityResult(
                    source: golden.source,
                    locator: locator,
                    listedLocators: listedLocators,
                    sessionInfo: sessionInfo,
                    messages: messages,
                    toolCalls: toolCalls,
                    usageTotals: Self.totalUsage(messages),
                    failure: failure
                )
            )
        }
        return results
    }

    func resolveLocator(_ locator: String) -> String {
        if locator.hasPrefix("/") { return locator }
        return fixtureRoot.appendingPathComponent(locator).path
    }

    func expectedSessionInfo(for golden: AdapterGolden) -> NormalizedSessionInfo? {
        guard var info = golden.sessionInfo else { return nil }
        info.filePath = info.filePath.replacingOccurrences(
            of: "<fixtureRoot>",
            with: fixtureRoot.path
        )
        return info
    }

    static func totalUsage(_ messages: [NormalizedMessage]) -> TokenUsage {
        messages.reduce(TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)) {
            partial,
            message in
            guard let usage = message.usage else { return partial }
            return TokenUsage(
                inputTokens: partial.inputTokens + usage.inputTokens,
                outputTokens: partial.outputTokens + usage.outputTokens,
                cacheReadTokens: (partial.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0),
                cacheCreationTokens: (partial.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
            )
        }
    }
}

public enum DefaultSessionAdapters {
    public static func make() -> [any SessionAdapter] {
        [
            CodexAdapter(),
            ClaudeCodeAdapter(),
            ClaudeCodeDerivedSourceAdapter(source: .minimax),
            ClaudeCodeDerivedSourceAdapter(source: .lobsterai),
            GeminiCliAdapter(),
            OpenCodeAdapter(),
            IflowAdapter(),
            QwenAdapter(),
            KimiAdapter(),
            PiAdapter(),
            ClineAdapter(),
            CursorAdapter(),
            VsCodeAdapter(),
            WindsurfAdapter(enableLiveSync: false),
            AntigravityAdapter(enableLiveSync: false),
            CopilotAdapter()
        ]
    }
}

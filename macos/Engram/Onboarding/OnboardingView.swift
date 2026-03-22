// macos/Engram/Onboarding/OnboardingView.swift
import SwiftUI

/// First-run onboarding: 3-step flow (Welcome -> Sources -> Ready).
struct OnboardingView: View {
    @State private var step = 0
    @State private var detectedSources: [SourceCheck] = []
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Step indicators
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(i <= step ? Theme.accent : Theme.surfaceHighlight)
                        .frame(width: i == step ? 20 : 8, height: 4)
                        .animation(.easeInOut(duration: 0.25), value: step)
                }
            }
            .padding(.top, 20)

            Spacer()

            Group {
                switch step {
                case 0:  welcomeStep
                case 1:  sourcesStep
                default: readyStep
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))

            Spacer()
        }
        .frame(width: 460, height: 380)
        .background(Theme.background)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)

            Text("Welcome to Engram")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Text("Cross-tool AI session aggregator")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)

            Button(action: {
                detectedSources = scanSources()
                withAnimation { step = 1 }
            }) {
                Text("Get Started")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 140, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 8)
        }
    }

    // MARK: - Step 2: Sources Detected

    private var sourcesStep: some View {
        VStack(spacing: 16) {
            Text("Sources Detected")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Text("Engram found session data from these AI tools:")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(detectedSources) { source in
                        HStack(spacing: 10) {
                            Image(systemName: source.found ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(source.found ? Theme.green : Theme.gray)
                                .font(.system(size: 14))

                            Circle()
                                .fill(SourceColors.color(for: source.id))
                                .frame(width: 8, height: 8)

                            Text(source.label)
                                .font(.system(size: 13))
                                .foregroundStyle(source.found ? Theme.primaryText : Theme.tertiaryText)

                            Spacer()

                            if source.found {
                                Text("found")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.green)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 180)
            .padding(.horizontal, 40)

            Button(action: { withAnimation { step = 2 } }) {
                Text("Continue")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 140, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 4)
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        let count = detectedSources.filter(\.found).count
        return VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.green)

            Text("\(count) source\(count == 1 ? "" : "s") detected, ready to index")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.primaryText)

            Text("Engram will index your sessions in the background.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: onComplete) {
                Text("Open Engram")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 140, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 8)
        }
    }
}

// MARK: - Source scanning

struct SourceCheck: Identifiable {
    let id: String      // adapter key, e.g. "claude-code"
    let label: String
    let path: String
    let found: Bool
}

private func scanSources() -> [SourceCheck] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let fm = FileManager.default

    let specs: [(id: String, label: String, relativePath: String)] = [
        ("claude-code",  "Claude Code",   ".claude/projects"),
        ("codex",        "Codex CLI",     ".codex/sessions"),
        ("gemini-cli",   "Gemini CLI",    ".gemini/tmp"),
        ("cursor",       "Cursor",        "Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
        ("windsurf",     "Windsurf",      ".codeium/windsurf"),
        ("cline",        "Cline",         ".cline/data/tasks"),
        ("copilot",      "Copilot",       ".copilot/session-state"),
        ("opencode",     "OpenCode",      ".local/share/opencode/opencode.db"),
        ("vscode",       "VS Code",       "Library/Application Support/Code/User/workspaceStorage"),
        ("kimi",         "Kimi",          ".kimi/sessions"),
        ("qwen",         "Qwen",          ".qwen/projects"),
        ("iflow",        "iFlow",         ".iflow/projects"),
        ("antigravity",  "Antigravity",   ".gemini/antigravity"),
    ]

    return specs.map { spec in
        let fullPath = (home as NSString).appendingPathComponent(spec.relativePath)
        return SourceCheck(
            id: spec.id,
            label: spec.label,
            path: fullPath,
            found: fm.fileExists(atPath: fullPath)
        )
    }
}

// macos/Engram/Views/Resume/ResumeDialog.swift
import SwiftUI

struct ResumeDialog: View {
    let session: Session
    private let availableTerminals: [TerminalType]
    @Environment(\.engramServiceClient) var serviceClient
    @Environment(\.dismiss) var dismiss
    @State private var resumeResult: ResumeInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var fallbackContextPrimer: String?
    @State private var selectedTerminal: TerminalType
    @State private var launchTask: Task<Void, Never>?

    struct ResumeInfo {
        let tool: String
        let command: String
        let args: [String]
        let cwd: String
        let contextPrimer: String?

        var trimmedContextPrimer: String? {
            guard let primer = contextPrimer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !primer.isEmpty else {
                return nil
            }
            return primer
        }
    }

    init(
        session: Session,
        availableTerminals: [TerminalType] = TerminalLauncher.availableTerminalTypes()
    ) {
        let terminalChoices = availableTerminals.isEmpty ? [.terminal] : availableTerminals
        self.session = session
        self.availableTerminals = terminalChoices
        self._selectedTerminal = State(initialValue: terminalChoices[0])
    }

    private var availableContextPrimer: String? {
        if let primer = resumeResult?.trimmedContextPrimer {
            return primer
        }
        guard let primer = fallbackContextPrimer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !primer.isEmpty else {
            return nil
        }
        return primer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume Session")
                .font(.headline)
            Text("\(session.displayTitle) · \(session.source)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Min-height anchor: loading → error/success swaps must not resize
            // the dialog under the user's cursor.
            Group {
                if isLoading {
                    ProgressView("Detecting CLI...")
                        .frame(maxWidth: .infinity)
                } else if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.red)
                        .font(.caption)
                        // VoiceOver reads the icon glyph as "exclamationmark triangle";
                        // spell out the role so the failure is announced plainly.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Unable to resume session")
                        .accessibilityValue(error)
                } else if let info = resumeResult {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle().fill(Theme.green).frame(width: 8, height: 8)
                            Text(info.tool).scaledFont(13, weight: .medium)
                            Text("detected").font(.caption).foregroundStyle(Theme.green)
                        }
                        Text(([info.command] + info.args).joined(separator: " "))
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(minHeight: 64, alignment: .top)

            if let primer = availableContextPrimer {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Context Primer", systemImage: "text.badge.checkmark")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button {
                            copyContextPrimer(primer)
                        } label: {
                            Label("Copy Primer", systemImage: "doc.on.doc")
                        }
                        .font(.caption)
                    }

                    ScrollView {
                        Text(primer)
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            if resumeResult != nil {
                Text("Launch in:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $selectedTerminal) {
                    ForEach(availableTerminals) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    launchTask?.cancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                if let info = resumeResult {
                    Button("Resume") {
                        launchTask?.cancel()
                        launchTask = Task {
                            do {
                                switch try await TerminalLauncher.launch(
                                    command: info.command,
                                    args: info.args,
                                    cwd: info.cwd,
                                    terminal: selectedTerminal
                                ) {
                                case .success:
                                    dismiss()
                                case .failure(let error):
                                    errorMessage = error.localizedDescription
                                }
                            } catch is CancellationError {
                                return
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .task {
            await fetchResumeInfo()
        }
        .onDisappear {
            launchTask?.cancel()
        }
    }

    func fetchResumeInfo() async {
        do {
            let response = try await serviceClient.resumeCommand(sessionId: session.id)
            try Task.checkCancellation()
            fallbackContextPrimer = response.contextPrimer
            if let error = response.error {
                errorMessage = error
                if let hint = response.hint, !hint.isEmpty {
                    errorMessage = "\(error)\n\(hint)"
                }
            } else if let command = response.command {
                resumeResult = ResumeInfo(
                    tool: response.tool ?? session.source,
                    command: command,
                    args: response.args,
                    cwd: response.cwd ?? "",
                    contextPrimer: response.contextPrimer
                )
            } else {
                errorMessage = "Resume command unavailable"
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Failed to build resume command"
        }
        isLoading = false
    }

    private func copyContextPrimer(_ primer: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(primer, forType: .string)
    }
}

// macos/Engram/Views/Resume/ResumeDialog.swift
import SwiftUI

struct ResumeDialog: View {
    let session: Session
    private let availableTerminals: [TerminalType]
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss
    @State private var resumeResult: ResumeInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var fallbackContextPrimer: String?
    @State private var selectedTerminal: TerminalType

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

            if isLoading {
                ProgressView("Detecting CLI...")
                    .frame(maxWidth: .infinity)
            } else if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if let info = resumeResult {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(info.tool).font(.system(size: 13, weight: .medium))
                        Text("detected").font(.caption).foregroundStyle(.green)
                    }
                    Text(([info.command] + info.args).joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

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
                            .font(.system(size: 11, design: .monospaced))
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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let info = resumeResult {
                    Button("Resume") {
                        TerminalLauncher.launch(
                            command: info.command,
                            args: info.args,
                            cwd: info.cwd,
                            terminal: selectedTerminal
                        )
                        dismiss()
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
    }

    func fetchResumeInfo() async {
        do {
            let response = try await serviceClient.resumeCommand(sessionId: session.id)
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

// macos/Engram/Views/Resume/ResumeDialog.swift
import SwiftUI

struct ResumeDialog: View {
    let session: Session
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss
    @State private var resumeResult: ResumeInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTerminal: TerminalType = .terminal

    struct ResumeInfo {
        let tool: String
        let command: String
        let args: [String]
        let cwd: String
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

                Text("Launch in:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $selectedTerminal) {
                    ForEach(TerminalType.allCases) { t in
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
                    cwd: response.cwd ?? ""
                )
            } else {
                errorMessage = "Resume command unavailable"
            }
        } catch {
            errorMessage = "Failed to build resume command"
        }
        isLoading = false
    }
}

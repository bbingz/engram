// macos/Engram/Views/Resume/ResumeDialog.swift
import SwiftUI

struct ResumeDialog: View {
    let session: Session
    @Environment(IndexerProcess.self) var indexer
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
        guard let port = indexer.port else {
            errorMessage = "Daemon not connected"
            isLoading = false
            return
        }
        do {
            let url = URL(string: "http://127.0.0.1:\(port)/api/session/\(session.id)/resume")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    errorMessage = error
                    if let hint = json["hint"] as? String, !hint.isEmpty {
                        errorMessage = "\(error)\n\(hint)"
                    }
                } else if let command = json["command"] as? String {
                    resumeResult = ResumeInfo(
                        tool: (json["tool"] as? String) ?? session.source,
                        command: command,
                        args: (json["args"] as? [String]) ?? [],
                        cwd: (json["cwd"] as? String) ?? ""
                    )
                }
            }
        } catch {
            errorMessage = "Failed to connect to daemon"
        }
        isLoading = false
    }
}

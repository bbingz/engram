// macos/Engram/Views/Settings/AboutSettingsSection.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AboutSettingsSection: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var isExportingDiagnostics = false
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "info.circle", title: "About")

            GroupBox("Database") {
                DatabaseInfoView()
                    .padding(.vertical, 4)
            }

            GroupBox("App") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await exportDiagnostics() }
                        } label: {
                            Label("Export Diagnostics…", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isExportingDiagnostics)
                        .accessibilityIdentifier("settings_export_diagnostics_button")

                        if isExportingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Spacer()
                    }

                    if let exportMessage {
                        Text(verbatim: exportMessage)
                            .font(.caption)
                            .foregroundStyle(exportMessage.hasPrefix("Export failed") ? Color.red : Color.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @MainActor
    private func exportDiagnostics() async {
        guard !isExportingDiagnostics else { return }
        guard let url = diagnosticsDestinationURL() else { return }

        isExportingDiagnostics = true
        exportMessage = nil
        defer { isExportingDiagnostics = false }

        do {
            let data = try await makeDiagnosticBundle()
            try data.write(to: url, options: [.atomic])
            exportMessage = "Exported \(url.lastPathComponent)"
        } catch {
            exportMessage = "Export failed: \(Self.shortErrorMessage(error))"
        }
    }

    @MainActor
    private func diagnosticsDestinationURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = Self.defaultDiagnosticFilename()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func makeDiagnosticBundle() async throws -> Data {
        let db = self.db
        let serviceClient = self.serviceClient

        async let serviceStatus = diagnosticServiceStatus(from: serviceClient)
        async let recentLogs = diagnosticServiceLogs(from: serviceClient)
        async let databaseStats: DiagnosticDatabaseStats = Task.detached {
            try db.diagnosticStats()
        }.value

        let input = DiagnosticBundleInput(
            app: DiagnosticAppInfo.current(),
            service: await serviceStatus,
            database: try await databaseStats,
            recentLogs: await recentLogs,
            settings: readEngramSettings() ?? [:]
        )
        return try DiagnosticBundleComposer.compose(input: input)
    }

    private func diagnosticServiceStatus(from serviceClient: EngramServiceClient) async -> DiagnosticServiceStatus {
        do {
            return .status(try await serviceClient.status())
        } catch {
            return .unreachable(message: Self.shortErrorMessage(error))
        }
    }

    private func diagnosticServiceLogs(from serviceClient: EngramServiceClient) async -> [DiagnosticLogLine] {
        do {
            return try await serviceClient.serviceLogs(level: nil, category: nil, limit: 200)
                .lines
                .map(DiagnosticLogLine.init)
        } catch {
            return []
        }
    }

    private static func defaultDiagnosticFilename() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "engram-diagnostics-\(formatter.string(from: Date())).json"
    }

    private static func shortErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        guard message.count > 240 else { return message }
        return "\(message.prefix(240))..."
    }
}

// MARK: - Database Info

struct DatabaseInfoView: View {
    @Environment(DatabaseManager.self) var db
    @State private var dbSize: String = "..."
    @State private var sessionCount: String = "..."
    private let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".engram/index.sqlite").path

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Path")
                Spacer()
                Text(verbatim: dbPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("Size")
                Spacer()
                Text(verbatim: dbSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Sessions")
                Spacer()
                Text(verbatim: sessionCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await loadInfo() }
    }

    private func loadInfo() async {
        // Off the main thread: a file stat plus a COUNT(*) over sessions.
        let db = self.db
        let path = dbPath
        let (size, count): (String, String) = await Task.detached {
            let size: String
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let bytes = attrs[.size] as? Int {
                size = String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
            } else {
                size = "N/A"
            }
            let count = "\((try? db.countSessions()) ?? 0)"
            return (size, count)
        }.value
        dbSize = size
        sessionCount = count
    }
}

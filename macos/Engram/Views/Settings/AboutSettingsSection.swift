// macos/Engram/Views/Settings/AboutSettingsSection.swift
import SwiftUI

struct AboutSettingsSection: View {
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
        }
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

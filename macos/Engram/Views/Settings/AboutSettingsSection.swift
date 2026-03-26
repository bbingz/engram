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
        .onAppear { loadInfo() }
    }

    private func loadInfo() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int {
            let mb = Double(size) / 1024 / 1024
            dbSize = String(format: "%.1f MB", mb)
        } else {
            dbSize = "N/A"
        }
        sessionCount = "\((try? db.countSessions()) ?? 0)"
    }
}

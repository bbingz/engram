// macos/Engram/Views/TopBarView.swift
import SwiftUI

struct TopBarView: View {
    @Binding var showSearch: Bool
    let selectedSession: Session?
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()

            // Global search button
            Button { showSearch.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Search sessions...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘K")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(width: 240)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            }
            .buttonStyle(.plain)

            // Resume button
            Button(action: onResume) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text("Resume")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selectedSession != nil ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08))
                .foregroundStyle(selectedSession != nil ? .green : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selectedSession != nil ? Color.green.opacity(0.3) : Color.secondary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(selectedSession == nil)
            .help(selectedSession != nil ? "Resume this session" : "Select a session to resume")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

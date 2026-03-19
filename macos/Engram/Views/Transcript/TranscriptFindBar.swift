// macos/Engram/Views/Transcript/TranscriptFindBar.swift
import SwiftUI

struct TranscriptFindBar: View {
    @Binding var searchText: String
    @Binding var isVisible: Bool
    let matchCount: Int
    let currentMatch: Int
    let onPrev: () -> Void
    let onNext: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Find in transcript...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 220)

            if !searchText.isEmpty {
                Text(matchCount > 0 ? "\(currentMatch + 1)/\(matchCount)" : "No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button(action: onPrev) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
            }

            Spacer()

            Button {
                searchText = ""
                isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { isFocused = true }
    }
}

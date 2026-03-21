// macos/Engram/Views/Transcript/TranscriptToolbar.swift
import SwiftUI

enum TranscriptViewMode: String, CaseIterable {
    case session, text, json
    var label: String { rawValue.capitalized }
}

struct TranscriptToolbar: View {
    let session: Session
    var onBack: (() -> Void)? = nil
    let isFavorite: Bool
    let typeCounts: [MessageType: Int]
    let typeVisibility: [MessageType: Bool]
    let navPositions: [MessageType: Int]

    let onToggleFavorite: () -> Void
    let onCopyAll: () -> Void
    let onToggleFind: () -> Void
    let onToggleType: (MessageType) -> Void
    let onShowAll: () -> Void
    let onNavPrev: (MessageType) -> Void
    let onNavNext: (MessageType) -> Void
    var onHandoff: (() -> Void)? = nil
    var onReplay: (() -> Void)? = nil

    @Binding var viewMode: TranscriptViewMode
    @AppStorage("contentFontSize") var fontSize: Double = 14

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Back button (only when navigated from main window)
                if let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)

                    Divider().frame(height: 14)
                }

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                Picker("", selection: $viewMode) {
                    ForEach(TranscriptViewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                } label: {
                    Text("ID \(String(session.id.suffix(4)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy session ID: \(session.id)")

                if let onHandoff {
                    Divider().frame(height: 14)

                    Button(action: onHandoff) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right.doc.on.clipboard")
                                .font(.system(size: 11))
                            Text("Handoff")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Generate handoff brief and copy to clipboard")
                }

                if let onReplay {
                    Button(action: onReplay) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 11))
                            Text("Replay")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Replay session timeline")
                }

                Spacer()

                Button { fontSize = max(10, fontSize - 1) } label: {
                    Text("A\u{2212}").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button { fontSize = min(22, fontSize + 1) } label: {
                    Text("A+").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                Button(action: onCopyAll) {
                    Text("Copy")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                Button(action: onToggleFind) {
                    Text("Find \u{2318}F")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if viewMode == .session {
                HStack(spacing: 10) {
                    Button(action: onShowAll) {
                        Text("All")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)

                    ForEach(MessageType.chipTypes, id: \.self) { type in
                        MessageTypeChip(
                            type: type,
                            currentIndex: navPositions[type] ?? -1,
                            totalCount: typeCounts[type] ?? 0,
                            isVisible: typeVisibility[type] ?? true,
                            onToggle: { onToggleType(type) },
                            onPrev: { onNavPrev(type) },
                            onNext: { onNavNext(type) }
                        )
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                Divider()
            }
        }
        .background(.bar)
    }
}

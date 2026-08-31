// macos/Engram/Views/Transcript/TranscriptToolbar.swift
import SwiftUI

enum TranscriptViewMode: String, CaseIterable {
    // UI-M2: removed the "JSON" case — it rendered identically to "Text"
    // (no raw-JSON data is retained on ChatMessage), so it was a false promise.
    case session, text
    var label: String { rawValue.capitalized }
}

struct TranscriptToolbar: View {
    let session: Session
    var onBack: (() -> Void)? = nil
    let isFavorite: Bool
    let typeCounts: [MessageType: Int]
    let typeVisibility: [MessageType: Bool]
    let navPositions: [MessageType: Int]
    // When the transcript is only partially loaded, chip counts and chip Prev/Next
    // reflect just the loaded prefix; the chips render "N+" so they don't read as
    // authoritative session totals.
    var partiallyLoaded: Bool = false

    let onToggleFavorite: () -> Void
    let onCopyAll: () -> Void
    let onToggleFind: () -> Void
    let onToggleType: (MessageType) -> Void
    let onShowAll: () -> Void
    let onNavPrev: (MessageType) -> Void
    let onNavNext: (MessageType) -> Void
    var onHandoff: (() -> Void)? = nil
    var onReplay: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    /// When set, the Resume entry stays visible but disabled with this hover
    /// explanation (e.g. HQ snapshots: the source lives on HQ).
    var resumeDisabledReason: String? = nil

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
                        .scaledFont(12)
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Back to session list")

                    Divider().frame(height: 14)
                }

                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                        .scaledFont(13)
                }
                .buttonStyle(.plain)
                // UI-H3: icon-only button needs a VoiceOver label.
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")

                Divider().frame(height: 14)

                Picker("", selection: $viewMode) {
                    ForEach(TranscriptViewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .accessibilityLabel("Transcript view mode")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                } label: {
                    Text("ID \(String(session.id.suffix(4)))")
                        .scaledFont(11)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy session ID: \(session.id)")

                // HQ-imported sessions also carry the snapshot caption in the
                // body; the toolbar badge is the second, always-visible cue.
                OriginBadge(origin: session.origin)

                if let onHandoff {
                    Divider().frame(height: 14)

                    Button(action: onHandoff) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right.doc.on.clipboard")
                                .scaledFont(11)
                            Text("Handoff")
                                .scaledFont(11)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Generate handoff brief and copy to clipboard")
                }

                if let onReplay {
                    Button(action: onReplay) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.rectangle")
                                .scaledFont(11)
                            Text("Replay")
                                .scaledFont(11)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Replay session timeline")
                }

                if let onResume {
                    Button(action: onResume) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .scaledFont(10)
                            Text("Resume")
                                .scaledFont(11)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(resumeDisabledReason != nil)
                    .opacity(resumeDisabledReason != nil ? 0.5 : 1)
                    .help(resumeDisabledReason ?? "Resume this session")
                }

                Spacer()

                Button { fontSize = max(10, fontSize - 1) } label: {
                    Text("A\u{2212}").scaledFont(12).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decrease text size")
                .help("Decrease transcript text size")

                Button { fontSize = min(22, fontSize + 1) } label: {
                    Text("A+").scaledFont(14).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Increase text size")
                .help("Increase transcript text size")

                Divider().frame(height: 14)

                Button(action: onCopyAll) {
                    Text("Copy")
                        .scaledFont(11)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Copy entire conversation")

                Divider().frame(height: 14)

                Button(action: onToggleFind) {
                    Text("Find \u{2318}F")
                        .scaledFont(11)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Find in transcript")
                .help("Find in transcript (⌘F)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if viewMode == .session {
                HStack(spacing: 10) {
                    Button(action: onShowAll) {
                        Text("All")
                            .scaledFont(11)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Show all message types")

                    ForEach(MessageType.chipTypes, id: \.self) { type in
                        MessageTypeChip(
                            type: type,
                            currentIndex: navPositions[type] ?? -1,
                            totalCount: typeCounts[type] ?? 0,
                            partiallyLoaded: partiallyLoaded,
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

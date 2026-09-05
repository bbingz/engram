// macos/Engram/Views/Replay/SessionReplayView.swift
import SwiftUI

struct SessionReplayView: View {
    let sessionId: String
    @Environment(\.engramServiceClient) var serviceClient
    @State private var replayState = ReplayState()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Session Replay")
                    .font(.headline)
                Spacer()
                if replayState.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if let error = replayState.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(Theme.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if replayState.entries.isEmpty && !replayState.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "play.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No timeline data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !replayState.entries.isEmpty {
                // Transport controls
                transportBar

                if let notice = replayState.truncationNotice {
                    Divider()

                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(notice)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("replay_truncationNotice")
                }

                Divider()

                // Density bar
                densityBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                Divider()

                // Current message display
                ScrollView {
                    if let entry = replayState.currentEntry {
                        messageView(entry)
                            .padding(16)
                            .id(entry.index)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .task { await loadTimeline() }
    }

    // MARK: - Transport Bar

    /// VoiceOver/help label for the play-pause toggle: names the action the
    /// button will take, mirroring the icon swap (Wave 8-5).
    static func playPauseLabel(isPlaying: Bool) -> String {
        isPlaying ? "Pause" : "Play"
    }

    private var transportBar: some View {
        HStack(spacing: 16) {
            // Step back
            Button(action: { replayState.stepBack() }) {
                Image(systemName: "backward.frame.fill")
                    .scaledFont(16)
            }
            .buttonStyle(.plain)
            .disabled(replayState.currentIndex <= 0)
            .accessibilityLabel("Step back")
            .help("Step back")

            // Play / Pause
            Button(action: {
                if replayState.isPlaying {
                    replayState.pause()
                } else {
                    replayState.play()
                }
            }) {
                Image(systemName: replayState.isPlaying ? "pause.fill" : "play.fill")
                    .scaledFont(20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.playPauseLabel(isPlaying: replayState.isPlaying))
            .help(Self.playPauseLabel(isPlaying: replayState.isPlaying))

            // Step forward
            Button(action: { replayState.stepForward() }) {
                Image(systemName: "forward.frame.fill")
                    .scaledFont(16)
            }
            .buttonStyle(.plain)
            .disabled(replayState.currentIndex >= replayState.entries.count - 1)
            .accessibilityLabel("Step forward")
            .help("Step forward")

            Divider().frame(height: 20)

            // Speed picker
            Picker("", selection: Binding(
                get: { replayState.playbackSpeed },
                set: { replayState.playbackSpeed = $0 }
            )) {
                ForEach(ReplayState.PlaybackSpeed.allCases, id: \.self) { speed in
                    Text(speed.label).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Playback speed")
            .frame(width: 120)

            Spacer()

            // Position indicator
            Text(replayState.progress)
                .scaledFont(12, design: .monospaced)
                .foregroundStyle(.secondary)

            // Scrubber
            Slider(
                value: Binding(
                    get: { replayState.progressFraction },
                    set: { replayState.seekToFraction($0) }
                ),
                in: 0...1
            )
            .frame(width: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Density Bar

    private var densityBar: some View {
        let buckets = replayState.densityBuckets
        let maxCount = buckets.max() ?? 1
        let currentBucket = replayState.entries.count > 1
            ? Int(Double(replayState.currentIndex) / Double(replayState.entries.count - 1) * 99)
            : 0

        return GeometryReader { geo in
            HStack(spacing: 0.5) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, count in
                    let intensity = maxCount > 0 ? Double(count) / Double(maxCount) : 0

                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15 + intensity * 0.7))
                        .overlay(
                            index == currentBucket
                                ? Color.white.opacity(0.5)
                                : Color.clear
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = location.x / geo.size.width
                replayState.seekToFraction(max(0, min(1, fraction)))
            }
        }
        .frame(height: 16)
    }

    // MARK: - Message View

    private func messageView(_ entry: ReplayTimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: role + type + timestamp
            HStack(spacing: 8) {
                Text(entry.role.capitalized)
                    .scaledFont(11, weight: .semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(roleColor(entry.role).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(roleColor(entry.role))

                Text(entry.type)
                    .scaledFont(10)
                    .foregroundStyle(.secondary)

                Spacer()

                if let ts = entry.timestamp {
                    Text(ts.prefix(19).replacingOccurrences(of: "T", with: " "))
                        .scaledFont(10, design: .monospaced)
                        .foregroundStyle(.tertiary)
                }

                if let tokens = entry.tokens, tokens > 0 {
                    Text("\(tokens) tok")
                        .scaledFont(10)
                        .foregroundStyle(.tertiary)
                }
            }

            // Content
            Text(entry.preview)
                .scaledFont(13)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(roleColor(entry.role).opacity(0.2), lineWidth: 2)
        )
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "user": return MessageType.user.color
        case "assistant": return MessageType.assistant.color
        case "tool": return MessageType.tool.color
        // FTS 回退路径可能出现 "unknown"，用中性色而非工具色
        default: return Theme.secondaryText
        }
    }

    // MARK: - Data Loading

    private func loadTimeline() async {
        replayState.isLoading = true
        defer { replayState.isLoading = false }

        do {
            let response = try await serviceClient.replayTimeline(sessionId: sessionId, limit: 2_000)
            let entries = response.entries.map { entry in
                ReplayTimelineEntry(
                    index: entry.index,
                    role: entry.role,
                    type: entry.type,
                    preview: entry.preview,
                    timestamp: entry.timestamp,
                    tokens: entry.tokens.map { $0.input + $0.output },
                    durationToNextMs: entry.durationToNextMs
                )
            }
            replayState.replaceTimeline(
                entries,
                totalEntries: response.totalEntries,
                hasMore: response.hasMore == true
            )
        } catch {
            replayState.error = error.localizedDescription
        }
    }
}

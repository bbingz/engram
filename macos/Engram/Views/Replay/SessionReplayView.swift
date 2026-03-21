// macos/Engram/Views/Replay/SessionReplayView.swift
import SwiftUI

struct SessionReplayView: View {
    let sessionId: String
    @EnvironmentObject var daemonClient: DaemonClient
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
                        .foregroundStyle(.orange)
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

    private var transportBar: some View {
        HStack(spacing: 16) {
            // Step back
            Button(action: { replayState.stepBack() }) {
                Image(systemName: "backward.frame.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(replayState.currentIndex <= 0)

            // Play / Pause
            Button(action: {
                if replayState.isPlaying {
                    replayState.pause()
                } else {
                    replayState.play()
                }
            }) {
                Image(systemName: replayState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)

            // Step forward
            Button(action: { replayState.stepForward() }) {
                Image(systemName: "forward.frame.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(replayState.currentIndex >= replayState.entries.count - 1)

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
            .frame(width: 120)

            Spacer()

            // Position indicator
            Text(replayState.progress)
                .font(.system(size: 12, design: .monospaced))
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
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(roleColor(entry.role).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(roleColor(entry.role))

                Text(entry.type)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                if let ts = entry.timestamp {
                    Text(ts.prefix(19).replacingOccurrences(of: "T", with: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if let tokens = entry.tokens, tokens > 0 {
                    Text("\(tokens) tok")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            // Content
            Text(entry.preview)
                .font(.system(size: 13))
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
        default: return MessageType.tool.color
        }
    }

    // MARK: - Data Loading

    private func loadTimeline() async {
        replayState.isLoading = true
        defer { replayState.isLoading = false }

        do {
            let response: ReplayTimelineResponse = try await daemonClient.fetch(
                "/api/sessions/\(sessionId)/timeline?limit=500"
            )
            replayState.entries = response.entries
        } catch {
            replayState.error = error.localizedDescription
        }
    }
}

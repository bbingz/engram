// macos/Engram/Models/ReplayState.swift
import Foundation

struct ReplayTimelineEntry: Equatable, Identifiable, Sendable {
    var id: Int { index }
    let index: Int
    let role: String
    let type: String
    let preview: String
    let timestamp: String?
    let tokens: Int?
    let durationToNextMs: Int?
}

@MainActor
@Observable
class ReplayState {
    var entries: [ReplayTimelineEntry] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var playbackSpeed: PlaybackSpeed = .x1
    var isLoading: Bool = false
    var error: String? = nil

    private var playTimer: Timer?

    enum PlaybackSpeed: Double, CaseIterable {
        case x1 = 1.0
        case x2 = 2.0
        case x4 = 4.0

        var label: String {
            switch self {
            case .x1: return "1x"
            case .x2: return "2x"
            case .x4: return "4x"
            }
        }
    }

    var currentEntry: ReplayTimelineEntry? {
        guard currentIndex >= 0 && currentIndex < entries.count else { return nil }
        return entries[currentIndex]
    }

    var progress: String {
        "\(currentIndex + 1) / \(entries.count)"
    }

    var progressFraction: Double {
        guard entries.count > 1 else { return 0 }
        return Double(currentIndex) / Double(entries.count - 1)
    }

    // MARK: - Density buckets (100 buckets for density bar)

    var densityBuckets: [Int] {
        guard entries.count >= 2,
              let first = entries.first?.timestamp,
              let last = entries.last?.timestamp else {
            return Array(repeating: 0, count: 100)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let startDate = formatter.date(from: first),
              let endDate = formatter.date(from: last) else {
            return Array(repeating: 0, count: 100)
        }

        let totalDuration = endDate.timeIntervalSince(startDate)
        guard totalDuration > 0 else {
            var buckets = Array(repeating: 0, count: 100)
            buckets[0] = entries.count
            return buckets
        }

        var buckets = Array(repeating: 0, count: 100)
        for entry in entries {
            guard let ts = entry.timestamp,
                  let date = formatter.date(from: ts) else { continue }
            let fraction = date.timeIntervalSince(startDate) / totalDuration
            let bucket = min(99, Int(fraction * 100))
            buckets[bucket] += 1
        }
        return buckets
    }

    // MARK: - Playback controls

    func play() {
        guard !entries.isEmpty else { return }
        isPlaying = true
        scheduleNext()
    }

    func pause() {
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
    }

    func stepForward() {
        guard currentIndex < entries.count - 1 else {
            pause()
            return
        }
        currentIndex += 1
    }

    func stepBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    func seekTo(_ index: Int) {
        currentIndex = max(0, min(entries.count - 1, index))
    }

    func seekToFraction(_ fraction: Double) {
        guard entries.count > 1 else { return }
        let index = Int(fraction * Double(entries.count - 1))
        seekTo(index)
    }

    // MARK: - Internal

    private func scheduleNext() {
        guard isPlaying, currentIndex < entries.count - 1 else {
            if currentIndex >= entries.count - 1 { pause() }
            return
        }

        // Use durationToNextMs if available, otherwise default 500ms
        let delayMs = entries[currentIndex].durationToNextMs ?? 500
        let scaledDelay = Double(delayMs) / (playbackSpeed.rawValue * 1000.0)
        // Cap at 3 seconds to avoid long waits
        let cappedDelay = min(scaledDelay, 3.0)

        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, cappedDelay), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentIndex += 1
                self.scheduleNext()
            }
        }
    }

    nonisolated deinit {
        // Timer cleanup handled by stop() or pause() calls
    }
}

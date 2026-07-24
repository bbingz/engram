// macos/Engram/Support/PerfSignpost.swift
// App-process perf instrumentation (row 16). DEBUG spans + optional main-thread
// stall monitor; Release ships a signature-identical no-op so call sites stay
// unguarded (as-main 838c7396 lesson).
import Foundation
import os

#if DEBUG
import os.signpost

enum Perf {
    private static let log = OSLog(subsystem: "com.engram.perf", category: "Perf")

    struct Span {
        let name: StaticString
        let id: OSSignpostID
        let start: CFAbsoluteTime
        let thresholdMs: Double
        let detail: () -> String
    }

    /// Begin a named span. `detail` is `@escaping @autoclosure` so under-threshold
    /// spans (the common case) never build the interpolated string.
    static func begin(
        _ name: StaticString,
        thresholdMs: Double = 16,
        _ detail: @escaping @autoclosure () -> String = ""
    ) -> Span {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Span(
            name: name,
            id: id,
            start: CFAbsoluteTimeGetCurrent(),
            thresholdMs: thresholdMs,
            detail: detail
        )
    }

    static func end(_ span: Span, _ extra: @escaping @autoclosure () -> String = "") {
        os_signpost(.end, log: log, name: span.name, signpostID: span.id)
        let ms = (CFAbsoluteTimeGetCurrent() - span.start) * 1000
        guard ms >= span.thresholdMs else { return }
        let detail = span.detail()
        let extraText = extra()
        if detail.isEmpty && extraText.isEmpty {
            print(String(format: "[perf] %@ %.1fms", "\(span.name)", ms))
        } else if extraText.isEmpty {
            print(String(format: "[perf] %@ %.1fms %@", "\(span.name)", ms, detail))
        } else if detail.isEmpty {
            print(String(format: "[perf] %@ %.1fms %@", "\(span.name)", ms, extraText))
        } else {
            print(String(format: "[perf] %@ %.1fms %@ %@", "\(span.name)", ms, detail, extraText))
        }
    }

    static func event(_ name: StaticString, _ detail: @escaping @autoclosure () -> String = "") {
        let text = detail()
        if text.isEmpty {
            os_signpost(.event, log: log, name: name)
            print("[perf][event] \(name)")
        } else {
            os_signpost(.event, log: log, name: name, "%{public}s", text)
            print("[perf][event] \(name) \(text)")
        }
    }
}

/// Opt-in main-thread stall watchdog. Starts only when `ENGRAM_PERF_MONITOR` is
/// set — deliberately distinct from CI's `ENGRAM_PERF` indexer flag.
@MainActor
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()

    private var timer: DispatchSourceTimer?
    private var lastBeat = CFAbsoluteTimeGetCurrent()
    private let intervalMs: Double = 50
    private let stallThresholdMs: Double = 200

    func start() {
        guard ProcessInfo.processInfo.environment["ENGRAM_PERF_MONITOR"] != nil else {
            return
        }
        guard timer == nil else { return }
        lastBeat = CFAbsoluteTimeGetCurrent()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + .milliseconds(Int(intervalMs)),
            repeating: .milliseconds(Int(intervalMs))
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let gapMs = (now - self.lastBeat) * 1000
            self.lastBeat = now
            if gapMs >= self.stallThresholdMs {
                print(String(format: "[perf][STALL] main thread blocked ~%.0fms", gapMs))
            }
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

#else

enum Perf {
    struct Span {}

    @inline(__always)
    static func begin(
        _ name: StaticString,
        thresholdMs: Double = 16,
        _ detail: @escaping @autoclosure () -> String = ""
    ) -> Span {
        Span()
    }

    @inline(__always)
    static func end(_ span: Span, _ extra: @escaping @autoclosure () -> String = "") {}

    @inline(__always)
    static func event(_ name: StaticString, _ detail: @escaping @autoclosure () -> String = "") {}
}

#endif

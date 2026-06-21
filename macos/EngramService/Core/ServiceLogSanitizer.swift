// macos/EngramService/Core/ServiceLogSanitizer.swift
import Foundation

/// Deny-by-default sanitizer for the in-process service log ring buffer.
///
/// The os_log call in `ServiceLogger` stays `privacy: .private` so nothing leaks
/// to the system log. To make the gated Observability "Logs" tab readable we tee
/// a *sanitized* copy of each line into `ServiceLogRing`. Sanitization is the
/// security boundary: it must elide every risky span (absolute paths, the home
/// dir, the runtime socket path, email addresses, UUID/session-id-shaped tokens,
/// and long free-text error tails) while preserving the structural prefix
/// ("ipc listener ready", "schema migration complete") so the line stays useful.
///
/// Order matters: structured shapes (paths, ids, emails) are redacted BEFORE the
/// generic long-free-text pass so a path embedded in an error tail is caught as a
/// `<path>` rather than swallowed whole into `<redacted>`.
enum ServiceLogSanitizer {
    // Absolute filesystem paths under the roots that carry user-identifying data.
    // Greedy over path characters so a trailing component (e.g. index.sqlite) is
    // consumed too. Whitespace/quotes terminate the run.
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?:/Users|/private|/var|/home|/tmp)/[^\s"'\)\]]*"#
    )

    // Email addresses.
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    )

    // Canonical UUID (session ids, migration ids, capability tokens shaped this
    // way). Case-insensitive; word-bounded so it does not bite into longer hex.
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#
    )

    // Long opaque hex/identifier tokens (32+ hex chars: capability tokens,
    // hashes, rollup ids) that are not UUID-shaped.
    private static let hexTokenRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{32,}\b"#
    )

    // Double-quoted spans (often embed file names, queries, or error text).
    private static let quotedRegex = try! NSRegularExpression(
        pattern: #""[^"]*""#
    )

    // Long free-text error tail. `ServiceLogger.error` composes
    // "\(message): \(error.localizedDescription)" — the localized description is
    // unbounded operator/OS text, so once the structured shapes are gone we elide
    // any remaining long run that follows the FIRST ": " delimiter. The
    // structural prefix before that delimiter (e.g. "remoteOffload failed")
    // survives. Bounded short tails (e.g. "ok") are left readable.
    private static let errorTailRegex = try! NSRegularExpression(
        pattern: #": .{25,}$"#
    )

    // The current user's home directory, redacted as a literal so a bare
    // "/Users/<name>" reference outside a path-shaped run is still caught. This
    // is a defense-in-depth pass on top of pathRegex.
    private static let homeDirectory: String = {
        FileManager.default.homeDirectoryForCurrentUser.path
    }()

    /// Sanitize one log message. Deny-by-default: every risky span is elided and
    /// only the structural, non-identifying remainder survives.
    static func redact(_ message: String) -> String {
        var output = message

        // 1. Literal home-dir prefix first (covers "/Users/bing/..." even when
        //    the trailing run is short).
        if !homeDirectory.isEmpty {
            output = output.replacingOccurrences(of: homeDirectory, with: "<path>")
        }

        // 2. Structured shapes, most specific first, so a path/id embedded in an
        //    error tail is caught as <path>/<id> before the generic tail pass.
        output = replace(emailRegex, in: output, with: "<email>")
        output = replace(pathRegex, in: output, with: "<path>")
        output = replace(uuidRegex, in: output, with: "<id>")
        output = replace(hexTokenRegex, in: output, with: "<id>")
        output = replace(quotedRegex, in: output, with: "<redacted>")

        // 3. Generic deny-by-default tail: anything long after the first ": ".
        output = replace(errorTailRegex, in: output, with: ": <redacted>")

        return output
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in input: String,
        with template: String
    ) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

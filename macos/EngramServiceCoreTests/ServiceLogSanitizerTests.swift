import XCTest
@testable import EngramServiceCore

/// PRIMARY SECURITY GATE for the readable-log feature: the in-process ring tees
/// a SANITIZED copy of every service log line. If the sanitizer leaks a raw
/// path / id / email / error tail, that data reaches the (dev-tools-gated, but
/// still readable) Observability "Logs" tab. These tests assert deny-by-default:
/// the structural prefix survives, every risky span is elided.
final class ServiceLogSanitizerTests: XCTestCase {
    func testAbsolutePathIsRedacted() {
        let raw = "indexing database /Users/bing/.engram/index.sqlite for scan"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains("/Users/bing/.engram/index.sqlite"))
        XCTAssertFalse(out.contains("/Users/bing"))
        XCTAssertTrue(out.contains("<path>"))
        // Structural prefix survives.
        XCTAssertTrue(out.contains("indexing database"))
    }

    func testHomeDirectoryIsRedacted() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = "settings loaded from \(home)/settings.json"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains(home))
        XCTAssertTrue(out.contains("<path>"))
        XCTAssertTrue(out.contains("settings loaded from"))
    }

    func testHomePathTailIsNotLeftBehind() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = "index opened \(home)/.engram/index.sqlite"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains(home))
        XCTAssertFalse(out.contains(".engram/index.sqlite"))
        XCTAssertEqual(out, "index opened <path>")
    }

    func testRuntimeSocketPathIsRedacted() {
        let raw = "ipc listener bound to /var/folders/xx/engram-run/service.sock"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains("/var/folders/xx/engram-run/service.sock"))
        XCTAssertTrue(out.contains("<path>"))
        XCTAssertTrue(out.contains("ipc listener bound to"))
    }

    func testExternalVolumePathIsRedacted() {
        let raw = "indexed /Volumes/ExternalDrive/work/project/index.sqlite"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains("/Volumes/ExternalDrive/work/project/index.sqlite"))
        XCTAssertTrue(out.contains("<path>"))
    }

    func testEmailIsRedacted() {
        let raw = "usage snapshot for account zzbhlx@gmail.com refreshed"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains("zzbhlx@gmail.com"))
        XCTAssertTrue(out.contains("<email>"))
        XCTAssertTrue(out.contains("usage snapshot for account"))
    }

    func testUuidSessionIdIsRedacted() {
        let raw = "linked session 3F2504E0-4F89-41D3-9A0C-0305E82C3301 to parent"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains("3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
        XCTAssertTrue(out.contains("<id>"))
        XCTAssertTrue(out.contains("linked session"))
    }

    func testLongOpaqueTokenIsRedacted() {
        let token = "deadbeefcafef00ddeadbeefcafef00ddeadbeefcafef00d"
        let raw = "capability token \(token) accepted"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("<id>"))
        XCTAssertTrue(out.contains("capability token"))
    }

    func testErrorLocalizedDescriptionTailIsRedacted() {
        // ServiceLogger.error composes "\(message): \(error.localizedDescription)".
        // The localized description is unbounded operator/OS text and must not
        // survive verbatim; the structural prefix before ": " must.
        let body = "The file could not be opened because you do not have permission to view it at this location."
        let raw = "remoteOffload failed: \(body)"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertFalse(out.contains(body))
        XCTAssertTrue(out.contains("remoteOffload failed"))
        XCTAssertTrue(out.contains("<redacted>"))
    }

    func testSafeStructuralLinePassesThroughReadable() {
        let raw = "ipc listener ready"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertEqual(out, "ipc listener ready")
    }

    func testStructuralPrefixWithCountSurvives() {
        // Counts and short structured key=value pairs are not sensitive and must
        // stay readable.
        let raw = "schema migration complete tables=42"
        let out = ServiceLogSanitizer.redact(raw)
        XCTAssertEqual(out, "schema migration complete tables=42")
    }
}

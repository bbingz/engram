import XCTest
@testable import EngramServiceCore

final class TranscriptExportServiceTests: XCTestCase {
    func testRedactionCoversCommonTokenFamilies() {
        let input = """
        github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ
        AKIA1234567890ABCDEF
        npm_1234567890abcdef
        xoxe-1234567890-abcdef
        -----BEGIN PRIVATE KEY-----
        secret
        -----END PRIVATE KEY-----
        """
        let redacted = TranscriptExportService.redactSensitiveContent(input)

        XCTAssertFalse(redacted.contains("github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertFalse(redacted.contains("AKIA1234567890ABCDEF"))
        XCTAssertFalse(redacted.contains("npm_1234567890abcdef"))
        XCTAssertFalse(redacted.contains("xoxe-1234567890-abcdef"))
        XCTAssertFalse(redacted.contains("BEGIN PRIVATE KEY"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testRedactionStaticPatternsProduceByteIdenticalOutput() {
        let samples = [
            "api_key: ABCDEF0123456789 tail",
            "Authorization: Bearer ABCDEF0123456789",
            "token=sk-abcdefghij0123456789 done",
            "github_pat_1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ here",
            "AKIA1234567890ABCDEF and npm_1234567890abcdef and xoxe-1234567890-abcdef",
            "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----",
            "no secrets here, just prose about tokens and passwords in general",
        ]
        let expected = [
            "[REDACTED] tail",
            "[REDACTED]",
            "[REDACTED] done",
            "[REDACTED] here",
            "[REDACTED] and [REDACTED] and [REDACTED]",
            "[REDACTED]",
            "no secrets here, just prose about tokens and passwords in general",
        ]
        for (input, want) in zip(samples, expected) {
            let first = TranscriptExportService.redactSensitiveContent(input)
            XCTAssertEqual(first, want, "redaction output changed for: \(input)")
            XCTAssertEqual(TranscriptExportService.redactSensitiveContent(input), first)
        }
    }
}

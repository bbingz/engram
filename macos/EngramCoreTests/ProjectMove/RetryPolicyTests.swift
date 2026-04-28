// macos/EngramCoreTests/ProjectMove/RetryPolicyTests.swift
// Mirrors tests/core/project-move/retry-policy.test.ts (Node parity baseline).
// Real error types arrive in later stages; for now we use a stub
// `ProjectMoveError` to exercise the envelope/details path. The classifier
// + sanitizer + MCP humanization rely on string names only and are fully
// covered today.
import XCTest
@testable import EngramCoreWrite

final class RetryPolicyTests: XCTestCase {
    // MARK: - classifyRetryPolicy

    func testLockBusyMapsToWait() {
        XCTAssertEqual(RetryPolicyClassifier.classify(errorName: "LockBusyError"), .wait)
    }

    func testConcurrentModificationMapsToConditional() {
        XCTAssertEqual(
            RetryPolicyClassifier.classify(errorName: "ConcurrentModificationError"),
            .conditional
        )
    }

    func testTerminalErrorsMapToNever() {
        for name in [
            "DirCollisionError",
            "SharedEncodingCollisionError",
            "UndoStaleError",
            "UndoNotAllowedError",
            "InvalidUtf8Error",
        ] {
            XCTAssertEqual(
                RetryPolicyClassifier.classify(errorName: name),
                .never,
                "expected \(name) → never"
            )
        }
    }

    func testUnknownErrorsDefaultToNever() {
        // Round-4 unification: MCP defaulted to never, HTTP to safe;
        // unifying on never (safer than auto-retry).
        XCTAssertEqual(RetryPolicyClassifier.classify(errorName: "SomeRandomError"), .never)
        XCTAssertEqual(RetryPolicyClassifier.classify(errorName: nil), .never)
    }

    // MARK: - mapErrorStatus

    func testConflictClassesMapTo409() {
        for name in [
            "LockBusyError",
            "DirCollisionError",
            "SharedEncodingCollisionError",
            "UndoNotAllowedError",
            "UndoStaleError",
        ] {
            XCTAssertEqual(
                RetryPolicyClassifier.httpStatus(errorName: name),
                409,
                "expected \(name) → 409"
            )
        }
    }

    func testEverythingElseMapsTo500() {
        XCTAssertEqual(RetryPolicyClassifier.httpStatus(errorName: "Error"), 500)
        XCTAssertEqual(
            RetryPolicyClassifier.httpStatus(errorName: "ConcurrentModificationError"),
            500
        )
        XCTAssertEqual(RetryPolicyClassifier.httpStatus(errorName: nil), 500)
    }

    // MARK: - sanitizeProjectMoveMessage

    func testSanitizeStripsOrchestratorPrefix() {
        XCTAssertEqual(sanitizeProjectMoveMessage("project-move: foo"), "foo")
        XCTAssertEqual(sanitizeProjectMoveMessage("runProjectMove: bar"), "bar")
    }

    func testSanitizeHumanizesEnoentEaccesEexist() {
        XCTAssertTrue(
            sanitizeProjectMoveMessage("Error: ENOENT: no such file, open '/tmp/foo'")
                .contains("File or directory not found: /tmp/foo")
        )
        XCTAssertTrue(
            sanitizeProjectMoveMessage("Error: EACCES: permission denied, rename '/tmp/a'")
                .contains("Permission denied: /tmp/a")
        )
        XCTAssertTrue(
            sanitizeProjectMoveMessage("Error: EEXIST: file already exists, rename '/x/y'")
                .contains("Path already exists: /x/y")
        )
    }

    func testSanitizePreservesCommasInsideQuotedPaths() {
        // Round-4 fix: greedy capture up to closing single-quote so paths
        // containing commas (legal on APFS) survive.
        let input = "Error: ENOENT: no such file, open '/tmp/odd,name.txt'"
        let result = sanitizeProjectMoveMessage(input)
        XCTAssertTrue(result.contains("/tmp/odd,name.txt"), "got: \(result)")
    }

    func testSanitizeLeavesUnknownMessagesUntouched() {
        XCTAssertEqual(
            sanitizeProjectMoveMessage("just a regular error"),
            "just a regular error"
        )
    }

    func testSanitizeEmptyReturnsUnknownError() {
        XCTAssertEqual(sanitizeProjectMoveMessage(""), "Unknown error")
    }

    // MARK: - buildErrorEnvelope

    func testEnvelopeProjectMoveErrorPassesThroughDetails() {
        let stub = StubProjectMoveError(
            errorName: "DirCollisionError",
            errorMessage: "directory already exists",
            errorDetails: ErrorDetails(
                sourceId: "claude-code",
                oldDir: "/a/old",
                newDir: "/a/new"
            )
        )
        let env = buildErrorEnvelope(stub)
        XCTAssertEqual(env.error.name, "DirCollisionError")
        XCTAssertEqual(env.error.retryPolicy, .never)
        XCTAssertEqual(env.error.details?.sourceId, "claude-code")
        XCTAssertEqual(env.error.details?.oldDir, "/a/old")
        XCTAssertEqual(env.error.details?.newDir, "/a/new")
    }

    func testEnvelopeSharingCwdsPassesThrough() {
        let stub = StubProjectMoveError(
            errorName: "SharedEncodingCollisionError",
            errorMessage: "shared",
            errorDetails: ErrorDetails(
                sourceId: "gemini-cli",
                oldDir: "/proj",
                sharingCwds: ["/a/proj", "/b/proj"]
            )
        )
        let env = buildErrorEnvelope(stub)
        XCTAssertEqual(env.error.details?.sharingCwds, ["/a/proj", "/b/proj"])
    }

    func testEnvelopeMigrationIdAndStatePassesThrough() {
        let stub = StubProjectMoveError(
            errorName: "UndoNotAllowedError",
            errorMessage: "not allowed",
            errorDetails: ErrorDetails(migrationId: "m-42", state: "failed")
        )
        let env = buildErrorEnvelope(stub)
        XCTAssertEqual(env.error.details?.migrationId, "m-42")
        XCTAssertEqual(env.error.details?.state, "failed")
    }

    func testEnvelopePlainErrorOmitsDetails() {
        let env = buildErrorEnvelope(NSError(domain: "x", code: 1))
        XCTAssertNil(env.error.details)
    }

    func testEnvelopeSanitizeTrueAppliesWhenRequested() {
        let err = NSError(
            domain: "x",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "project-move: bad thing"]
        )
        let env = buildErrorEnvelope(err, sanitize: true)
        XCTAssertEqual(env.error.message, "bad thing")
    }

    func testEnvelopeSanitizeFalsePreservesRawMessage() {
        let err = NSError(
            domain: "x",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "project-move: bad thing"]
        )
        let env = buildErrorEnvelope(err, sanitize: false)
        XCTAssertEqual(env.error.message, "project-move: bad thing")
    }

    // MARK: - humanizeForMcp

    func testHumanizeKnownNamesHaveDedicatedGuidance() {
        let names = [
            "LockBusyError",
            "ConcurrentModificationError",
            "UndoStaleError",
            "UndoNotAllowedError",
            "InvalidUtf8Error",
            "DirCollisionError",
            "SharedEncodingCollisionError",
        ]
        for name in names {
            let stub = StubProjectMoveError(errorName: name, errorMessage: "raw-\(name)")
            let text = humanizeForMcp(stub)
            XCTAssertGreaterThan(
                text.count,
                stub.errorMessage.count,
                "\(name) guidance must add to raw message"
            )
            XCTAssertTrue(
                text.contains("raw-\(name)"),
                "\(name) guidance must include raw message"
            )
        }
    }

    func testHumanizeDirCollisionReferencesTargetDirectory() {
        let stub = StubProjectMoveError(
            errorName: "DirCollisionError",
            errorMessage: "x",
            errorDetails: ErrorDetails(sourceId: "claude-code", oldDir: "/a", newDir: "/b")
        )
        let text = humanizeForMcp(stub)
        XCTAssertNotNil(
            text.range(of: "target directory already exists", options: .caseInsensitive)
        )
    }

    func testHumanizeUnknownNamesFallThrough() {
        let stub = StubProjectMoveError(errorName: "SomeWeirdError", errorMessage: "unexpected")
        XCTAssertEqual(humanizeForMcp(stub), "SomeWeirdError: unexpected")
    }
}

// MARK: - test helpers

private struct StubProjectMoveError: ProjectMoveError {
    let errorName: String
    let errorMessage: String
    var errorDetails: ErrorDetails?

    init(errorName: String, errorMessage: String, errorDetails: ErrorDetails? = nil) {
        self.errorName = errorName
        self.errorMessage = errorMessage
        self.errorDetails = errorDetails
    }
}

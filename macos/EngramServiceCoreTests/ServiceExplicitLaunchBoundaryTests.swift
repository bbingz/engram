import Darwin
import Foundation
import XCTest
@testable import EngramServiceCore

final class ServiceExplicitLaunchBoundaryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = checkout.appendingPathComponent(".engram-service-launch-boundary-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testExpectedHomeIsOptionalAndAcceptsExactActualPath() throws {
        XCTAssertNoThrow(try engramServiceValidateExpectedHome(arguments: [], actualHome: root))
        XCTAssertNoThrow(try engramServiceValidateExpectedHome(
            arguments: ["--expected-home", root.path], actualHome: root))
        XCTAssertNoThrow(try engramServiceValidateExpectedHome(
            arguments: ["--database-path", root.appendingPathComponent("index.sqlite").path], actualHome: root))
    }

    func testExpectedHomeRejectsMissingDuplicateRelativeAndNormalizedAliases() throws {
        for arguments in malformedArguments(flag: "--expected-home") {
            XCTAssertThrowsError(try engramServiceValidateExpectedHome(arguments: arguments, actualHome: root),
                "must reject \(arguments)")
        }
        // These aliases would normalize to the actual home, so a mismatch-only
        // implementation cannot accidentally satisfy strict-path coverage.
        for alias in [root.path + "/.", root.path + "/child/..",
            root.deletingLastPathComponent().path + "//" + root.lastPathComponent, root.path + "/"] {
            XCTAssertThrowsError(try engramServiceValidateExpectedHome(
                arguments: ["--expected-home", alias], actualHome: root), "must not normalize \(alias)")
        }
    }

    func testExpectedHomeRejectsDifferentAndUnicodeEquivalentButByteDifferentPaths() throws {
        XCTAssertThrowsError(try engramServiceValidateExpectedHome(
            arguments: ["--expected-home", root.appendingPathComponent("other").path], actualHome: root))
        let actualHome = root.appendingPathComponent("cafe\u{0301}")
        let rawExpectedHome = actualHome.path.precomposedStringWithCanonicalMapping
        XCTAssertEqual(actualHome.path, rawExpectedHome, "the fixture must be canonically equivalent")
        XCTAssertNotEqual(Array(actualHome.path.utf8), Array(rawExpectedHome.utf8),
            "the fixture must retain distinct UTF8 bytes")
        XCTAssertThrowsError(try engramServiceValidateExpectedHome(
            arguments: ["--expected-home", rawExpectedHome], actualHome: actualHome))
    }

    func testCredentialFlagRejectsMissingDuplicateRelativeAndNormalizedAliasesWithoutFallback() throws {
        let calls = LaunchBoundaryCalls()
        for arguments in malformedArguments(flag: "--capture-credentials-file") {
            XCTAssertThrowsError(try engramServiceCaptureCredentialLoader(arguments: arguments, fallback: { reference in
                calls.record(reference)
                return "synthetic-fallback"
            }), "must reject \(arguments)")
        }
        XCTAssertEqual(calls.references, [])
    }

    func testNoCredentialFlagPreservesLazyFallbackValuesAndErrors() throws {
        let calls = LaunchBoundaryCalls()
        let loader = try engramServiceCaptureCredentialLoader(arguments: [], fallback: { reference in
            calls.record(reference)
            if reference == "throw" { throw LaunchBoundaryFailure.synthetic }
            return reference == "hq" ? "synthetic-fallback-hq" : nil
        })
        XCTAssertEqual(calls.references, [])
        XCTAssertEqual(try loader("hq"), "synthetic-fallback-hq")
        XCTAssertNil(try loader("missing"))
        XCTAssertThrowsError(try loader("throw")) { error in
            XCTAssertEqual(error as? LaunchBoundaryFailure, .synthetic)
        }
        XCTAssertEqual(calls.references, ["hq", "missing", "throw"])
    }

    func testExplicitCredentialFileIsNotReadUntilLoaderIsCalled() throws {
        let url = root.appendingPathComponent("created-after-construction.json")
        let calls = LaunchBoundaryCalls()
        let loader = try makeLoader(url: url, calls: calls)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(calls.references, [], "an OFF runtime never invokes this closure")
        try writeJSON(["hq": "synthetic-lazy-hq"], to: url)
        XCTAssertEqual(try loader("hq"), "synthetic-lazy-hq")
        XCTAssertEqual(calls.references, [])
    }

    func testExplicitCredentialFileReadsSyntheticHQAndM1WithoutFallback() throws {
        let url = root.appendingPathComponent("valid.json")
        try writeJSON(["hq": "synthetic-hq", "m1": "synthetic-m1"], to: url)
        let calls = LaunchBoundaryCalls()
        let loader = try makeLoader(url: url, calls: calls)
        XCTAssertEqual(calls.references, [])
        XCTAssertEqual(try loader("hq"), "synthetic-hq")
        XCTAssertEqual(try loader("m1"), "synthetic-m1")
        let boundaryURL = root.appendingPathComponent("valid-boundaries.json")
        let longest = String(repeating: "~", count: 4_096)
        try writeJSON(["hq": "!", "m1": longest], to: boundaryURL)
        let boundaryLoader = try makeLoader(url: boundaryURL, calls: calls)
        XCTAssertEqual(try boundaryLoader("hq"), "!")
        XCTAssertEqual(try boundaryLoader("m1"), longest)
        XCTAssertEqual(calls.references, [])
    }

    func testMissingAndUnsafeCredentialFilesFailLazilyWithoutRepairOrFallback() throws {
        let calls = LaunchBoundaryCalls()
        let missing = root.appendingPathComponent("missing.json")
        let missingLoader = try makeLoader(url: missing, calls: calls)
        XCTAssertThrowsError(try missingLoader("hq"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let unsafe = root.appendingPathComponent("unsafe.json")
        try writeJSON(["hq": "synthetic-hq"], to: unsafe)
        XCTAssertEqual(chmod(unsafe.path, 0o644), 0)
        let unsafeLoader = try makeLoader(url: unsafe, calls: calls)
        XCTAssertThrowsError(try unsafeLoader("hq"))
        let permissions = try FileManager.default.attributesOfItem(atPath: unsafe.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o644, "rejected explicit credentials must not be repaired")
        XCTAssertEqual(calls.references, [])
    }

    func testLeafAndAncestorCredentialSymlinksFailWithoutFallback() throws {
        let directory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("credentials.json")
        try writeJSON(["hq": "synthetic-hq"], to: file)
        let leaf = root.appendingPathComponent("leaf.json")
        let ancestor = root.appendingPathComponent("ancestor", isDirectory: true)
        XCTAssertEqual(symlink(file.path, leaf.path), 0)
        XCTAssertEqual(symlink(directory.path, ancestor.path), 0)
        let calls = LaunchBoundaryCalls()
        for url in [leaf, ancestor.appendingPathComponent("credentials.json")] {
            let loader = try makeLoader(url: url, calls: calls)
            XCTAssertThrowsError(try loader("hq"), "must not follow \(url.path)")
        }
        XCTAssertEqual(calls.references, [])
        XCTAssertEqual(try Data(contentsOf: file), try JSONSerialization.data(withJSONObject: ["hq": "synthetic-hq"], options: [.sortedKeys]))
    }

    func testInvalidMapsMissingReferencesAndInvalidTokensNeverFallBack() throws {
        let documents: [Any] = [
            ["hq": 17], ["hq": "synthetic-hq", "m1": false], ["synthetic-hq"], [:],
            ["m1": "synthetic-m1"], ["hq": ""], ["hq": String(repeating: "x", count: 4_097)],
            ["hq": "has space"], ["hq": "has\nnewline"], ["hq": "has\u{007F}delete"],
            ["hq": "nonascii-\u{00E9}"],
        ]
        let calls = LaunchBoundaryCalls()
        for (index, document) in documents.enumerated() {
            let url = root.appendingPathComponent("invalid-\(index).json")
            try writeJSON(document, to: url)
            let loader = try makeLoader(url: url, calls: calls)
            XCTAssertThrowsError(try loader("hq"), "invalid document \(index) must fail closed")
        }
        XCTAssertEqual(calls.references, [])
    }

    func testRunnerValidatesHomeAndConstructsLazyLoaderBeforeAnyOwnedStartupActivity() throws {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: macos.appendingPathComponent("EngramService/Core/EngramServiceRunner.swift"), encoding: .utf8)
        let signature = "    static func run(\n        arguments: [String],\n        environment: [String: String],\n        testHooks: RunnerTestHooks\n    ) async throws {"
        let entry = try XCTUnwrap(source.range(of: signature))
        let body = String(source[entry.upperBound...])
        let home = try XCTUnwrap(body.range(of: "engramServiceValidateExpectedHome("), "missing front-door home guard")
        let credentials = try XCTUnwrap(body.range(of: "engramServiceCaptureCredentialLoader("), "missing lazy explicit loader construction")
        XCTAssertLessThan(home.lowerBound, credentials.lowerBound)
        for activity in [
            "let runtimeHome =", "let implicitSocketPath =", "let settingsURL =",
            "UnixSocketEngramServiceTransport.secureRuntimeDirectory(", "FileManager.default.createDirectory(",
            "removeLegacyWebUIToken(", "ServiceWriterGate(", "ArchiveV2Settings.load(",
            "ClaudeCodeProfileService(", "RemoteSyncCoordinator.makeIfEnabled(",
            "ServiceCaptureIngestRuntime.make(", "UnixSocketServiceServer(",
        ] {
            let position = try XCTUnwrap(body.range(of: activity), "missing startup anchor \(activity)")
            XCTAssertLessThan(home.lowerBound, position.lowerBound, "home must be checked before \(activity)")
            XCTAssertLessThan(credentials.lowerBound, position.lowerBound, "loader must be constructed before \(activity)")
        }
    }

    private func malformedArguments(flag: String) -> [[String]] {
        [
            [flag], [flag, ""], [flag, "relative.json"], [flag, "~/credentials.json"],
            [flag, "--another-flag"], [flag, root.path, flag, root.path],
            [flag, root.path + "/./file"], [flag, root.path + "/child/../file"],
            [flag, root.path + "//file"], [flag, root.path + "/"],
        ]
    }

    private func makeLoader(url: URL, calls: LaunchBoundaryCalls) throws -> @Sendable (String) throws -> String? {
        try engramServiceCaptureCredentialLoader(arguments: ["--capture-credentials-file", url.path], fallback: { reference in
            calls.record(reference)
            return "synthetic-fallback-must-not-be-used"
        })
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
}

private enum LaunchBoundaryFailure: Error, Equatable {
    case synthetic
}

private final class LaunchBoundaryCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var references: [String] { lock.withLock { stored } }
    func record(_ reference: String) { lock.withLock { stored.append(reference) } }
}

/// No fixture or child exists unless the launcher provides the exact binary.
/// Every child has a home guard and must fail before any owned startup work.
final class ServiceExplicitLaunchBinaryBoundaryTests: XCTestCase {
    func testRealServiceRejectsWrongExpectedHomeBeforeOwnedStartup() async throws {
        try await assertRejectedLaunch(.wrongHome)
    }

    func testRealServiceRejectsDuplicateExpectedHomeBeforeOwnedStartup() async throws {
        try await assertRejectedLaunch(.duplicateHome)
    }

    func testRealServiceRejectsRelativeCredentialFileBeforeOwnedStartup() async throws {
        try await assertRejectedLaunch(.relativeCredentials)
    }

    private enum RejectedLaunch { case wrongHome, duplicateHome, relativeCredentials }

    private func assertRejectedLaunch(_ scenario: RejectedLaunch) async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["ENGRAM_SERVICE_BINARY"] else {
            throw XCTSkip("Native launch boundary requires explicit ENGRAM_SERVICE_BINARY; no binary lookup is performed")
        }
        guard binaryPath.hasPrefix("/"), !binaryPath.utf8.contains(0),
              FileManager.default.isExecutableFile(atPath: binaryPath) else {
            XCTFail("ENGRAM_SERVICE_BINARY must name an executable absolute path")
            return
        }
        let binary = URL(fileURLWithPath: binaryPath)
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = checkout.appendingPathComponent(".engram-service-launch-binary-test-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let database = owned.appendingPathComponent("index.sqlite")
        let socket = owned.appendingPathComponent("service.sock")
        let settings = home.appendingPathComponent(".engram/settings.json")
        var child: CLIIntegrationChild?
        var failure: Error?
        do {
            for directory in [root, home, temporary] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            var arguments = ["--expected-home", home.path,
                "--database-path", database.path, "--service-socket", socket.path]
            let expectedMessage: String
            switch scenario {
            case .wrongHome:
                arguments[1] = home.appendingPathComponent("must-not-match").path
                expectedMessage = "explicit home does not match actual home"
            case .duplicateHome:
                arguments += ["--expected-home", home.path]
                expectedMessage = "invalid explicit launch path"
            case .relativeCredentials:
                arguments += ["--capture-credentials-file", "synthetic-secret-must-not-be-echoed.json"]
                expectedMessage = "invalid explicit launch path"
            }
            let process = try CLIIntegrationChild(binary: binary, arguments: arguments,
                root: root, home: home, temporary: temporary, roleEnvironment: [
                    "ENGRAM_SETTINGS_PATH": settings.path,
                    "ENGRAM_RUNTIME_AI_SECRETS_PATH": home.appendingPathComponent("absent-ai-secrets.json").path,
                    "ENGRAM_REMOTE_OFFLOAD_ENABLED": "false",
                    "ENGRAM_LIVE_PUBLISH_ENABLED": "false",
                    "ENGRAM_LIVE_INGEST_ENABLED": "false",
                ])
            child = process
            let result = try await process.waitForExit(seconds: 5)
            XCTAssertEqual(result.reason, .exit, "rejection must finish normally, not by a timeout signal")
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(result.stderr.hasSuffix("EngramService failed: invalidRequest(message: \"\(expectedMessage)\")\n"),
                "stderr must end with the fixed boundary rejection, not a later runtime failure")
            XCTAssertFalse(result.stderr.contains(root.path))
            XCTAssertFalse(result.stderr.contains("synthetic-secret-must-not-be-echoed"))
            for absent in [owned, database, socket, settings, home.appendingPathComponent(".engram")] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path), "unexpected owned startup path \(absent.path)")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        } catch { failure = error }
        // Never remove a fixture while a child may still own paths within it.
        do { try await child?.stopAndJoin() }
        catch {
            XCTFail("child cleanup failed; private launch fixture retained")
            print("Retained private launch fixture: \(root.path)")
            throw error
        }
        if failure == nil, testRun?.failureCount == 0, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        } else {
            print("Retained private launch fixture: \(root.path)")
        }
        if let failure { throw failure }
    }
}

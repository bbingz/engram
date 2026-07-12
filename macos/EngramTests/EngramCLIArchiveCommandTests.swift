import XCTest
@testable import Engram

final class EngramCLIArchiveCommandTests: XCTestCase {
    func testParsesArchiveCommandsWithoutSocketOverride() throws {
        XCTAssertEqual(try EngramCLIArchiveCommand.parse(arguments: ["archive", "status", "--json"]), .status(json: true))
        XCTAssertEqual(try EngramCLIArchiveCommand.parse(arguments: ["archive", "retry", "--replica", "all"]), .retry(replicaID: nil, json: false))
        XCTAssertEqual(try EngramCLIArchiveCommand.parse(arguments: ["archive", "retry", "--replica", "m1", "--json"]), .retry(replicaID: "m1", json: true))
        XCTAssertEqual(try EngramCLIArchiveCommand.parse(arguments: ["archive", "token", "set", "--replica", "hq", "--stdin"]), .storeToken(replicaID: "hq", json: false))
        XCTAssertEqual(try EngramCLIArchiveCommand.parse(arguments: ["archive", "probe-remote", "--session-id", "session-1", "--json"]), .probeRemote(sessionID: "session-1", json: true))
        XCTAssertNil(try EngramCLIArchiveCommand.parse(arguments: ["resume", "session-1"]))
        XCTAssertThrowsError(try EngramCLIArchiveCommand.parse(arguments: ["archive", "unknown"]))
        XCTAssertThrowsError(try EngramCLIArchiveCommand.parse(arguments: ["archive", "status", "--socket", "/tmp/other.sock"]))
        for forbidden in ["--replica", "--url", "--path", "--digest", "--skip"] {
            XCTAssertThrowsError(
                try EngramCLIArchiveCommand.parse(
                    arguments: ["archive", "probe-remote", "--session-id", "session-1", forbidden, "value"]
                )
            )
        }
        XCTAssertThrowsError(try EngramCLIArchiveCommand.parse(arguments: ["archive", "probe-remote", "--session-id", ""]))
    }

    func testTokenInputRequiresNonTTYCanonicalSingleBase64LineOf32Bytes() throws {
        let canonical = Data(repeating: 0x5a, count: 32).base64EncodedString()
        XCTAssertEqual(try EngramCLIArchiveTokenInput.validate(canonical + "\n", stdinIsTTY: false, environment: [:]), canonical)
        XCTAssertThrowsError(try EngramCLIArchiveTokenInput.validate(canonical, stdinIsTTY: true, environment: [:]))
        XCTAssertThrowsError(try EngramCLIArchiveTokenInput.validate(canonical + "\nextra", stdinIsTTY: false, environment: [:]))
        XCTAssertThrowsError(try EngramCLIArchiveTokenInput.validate(canonical + "\0", stdinIsTTY: false, environment: [:]))
        XCTAssertThrowsError(try EngramCLIArchiveTokenInput.validate("YQ==", stdinIsTTY: false, environment: [:]))
        XCTAssertThrowsError(try EngramCLIArchiveTokenInput.validate("not-base64", stdinIsTTY: false, environment: [:]))
        XCTAssertThrowsError(try EngramCLIArchiveTokenInput.validate(canonical, stdinIsTTY: false, environment: ["ENGRAM_ARCHIVE_TOKEN": canonical]))
    }

    func testTokenCannotAppearInArguments() {
        let canonical = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertThrowsError(try EngramCLIArchiveCommand.parse(arguments: ["archive", "token", "set", "--replica", "hq", "--stdin", canonical]))
        XCTAssertThrowsError(try EngramCLIArchiveCommand.parse(arguments: ["archive", "token", "set", "--replica", "hq", "--token", canonical]))
    }
}

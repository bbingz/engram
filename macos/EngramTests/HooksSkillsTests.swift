import XCTest
@testable import Engram

final class HooksSkillsTests: XCTestCase {
    // Provider-side path population (FileSystemEngramServiceReadProvider.hooks()
    // emitting a non-empty path) is covered separately in EngramServiceCoreTests,
    // the only target that can see the provider. These tests cover the DTO field
    // this WP adds and the reveal helper's tilde-expansion contract.

    func testHookInfoCarriesAndDecodesPath() throws {
        let hook = EngramServiceHookInfo(
            event: "PostToolUse",
            command: "echo hi",
            scope: "global",
            path: "~/.claude/settings.json"
        )
        let data = try JSONEncoder().encode(hook)
        let decoded = try JSONDecoder().decode(EngramServiceHookInfo.self, from: data)
        XCTAssertEqual(decoded.path, "~/.claude/settings.json")
        XCTAssertEqual(decoded.id, "global/PostToolUse/echo hi")
        XCTAssertEqual(decoded, hook)
    }

    func testHookInfoDecodesServiceJSONWithPath() throws {
        let json = """
        {"event":"PreToolUse","command":"lint","scope":"project","path":"~/.claude/settings.local.json"}
        """
        let decoded = try JSONDecoder().decode(EngramServiceHookInfo.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.path, "~/.claude/settings.local.json")
        XCTAssertEqual(decoded.scope, "project")
    }

    func testRevealPathExpandsTilde() {
        let expanded = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        XCTAssertFalse(expanded.contains("~"))
        XCTAssertTrue(expanded.hasPrefix("/"))
    }
}

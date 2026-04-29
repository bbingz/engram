// macos/EngramCoreTests/ProjectMove/PathsTests.swift
// Mirrors the implicit contract of paths.ts. Node has no dedicated
// vitest file for paths.ts (it's covered transitively); we add explicit
// coverage here because the Swift port stands alone.
import Foundation
import XCTest
@testable import EngramCoreWrite

final class ProjectPathsTests: XCTestCase {
    private let fakeHome = URL(fileURLWithPath: "/tmp/fake-home")

    func testEmptyPathPassesThrough() {
        XCTAssertEqual(ProjectPath.expandHome("", homeDirectory: fakeHome), "")
    }

    func testPlainAbsolutePathUntouched() {
        XCTAssertEqual(
            ProjectPath.expandHome("/Users/example/-Code-/engram", homeDirectory: fakeHome),
            "/Users/example/-Code-/engram"
        )
    }

    func testRelativePathUntouched() {
        // expandHome only handles tilde; relative resolution is path.resolve's job.
        XCTAssertEqual(ProjectPath.expandHome("foo/bar", homeDirectory: fakeHome), "foo/bar")
    }

    func testBareTildeExpandsToHome() {
        XCTAssertEqual(ProjectPath.expandHome("~", homeDirectory: fakeHome), "/tmp/fake-home")
    }

    func testTildeSlashExpandsToHomePrefix() {
        XCTAssertEqual(
            ProjectPath.expandHome("~/code/engram", homeDirectory: fakeHome),
            "/tmp/fake-home/code/engram"
        )
    }

    func testTildeWithoutSlashIsNotExpanded() {
        // `~user` shorthand is intentionally NOT supported (Node parity).
        XCTAssertEqual(ProjectPath.expandHome("~user/code", homeDirectory: fakeHome), "~user/code")
    }
}

import XCTest
@testable import EngramServiceCore

/// Wave 7D H09: memoryFileContent must stay under ~/.claude/projects/*/memory/
/// and reject symlink / non-memory .md paths.
final class MemoryFileContentBoundsTests: XCTestCase {
    private func withTempHome(_ body: (URL, FileSystemEngramServiceReadProvider) async throws -> Void) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-memory-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = FileSystemEngramServiceReadProvider(homeDirectory: home)
        try await body(home, provider)
    }

    func testValidMemoryFileIsReadable_repro() async throws {
        try await withTempHome { home, provider in
            let memoryDir = home
                .appendingPathComponent(".claude/projects/my-proj/memory", isDirectory: true)
            try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
            let file = memoryDir.appendingPathComponent("note.md")
            try "hello memory".write(to: file, atomically: true, encoding: .utf8)

            let response = try await provider.memoryFileContent(
                EngramServiceMemoryFileContentRequest(path: file.path)
            )
            XCTAssertEqual(response.content, "hello memory")
            XCTAssertFalse(response.truncated)
        }
    }

    func testNonMemoryMarkdownIsRejected_repro() async throws {
        try await withTempHome { home, provider in
            let projects = home.appendingPathComponent(".claude/projects/my-proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            let file = projects.appendingPathComponent("secrets.md")
            try "should not read".write(to: file, atomically: true, encoding: .utf8)

            let response = try await provider.memoryFileContent(
                EngramServiceMemoryFileContentRequest(path: file.path)
            )
            XCTAssertEqual(response.content, "", "non-memory .md must return empty content")
        }
    }

    func testSymlinkEscapeIsRejected_repro() async throws {
        try await withTempHome { home, provider in
            let memoryDir = home
                .appendingPathComponent(".claude/projects/my-proj/memory", isDirectory: true)
            try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
            let outside = home.appendingPathComponent("outside-secret.md")
            try "secret".write(to: outside, atomically: true, encoding: .utf8)
            let link = memoryDir.appendingPathComponent("escape.md")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)

            let response = try await provider.memoryFileContent(
                EngramServiceMemoryFileContentRequest(path: link.path)
            )
            XCTAssertEqual(response.content, "", "symlink targets must not be readable")
        }
    }

    func testTildeDisplayPathUnderMemoryIsReadable_repro() async throws {
        try await withTempHome { home, provider in
            let memoryDir = home
                .appendingPathComponent(".claude/projects/my-proj/memory", isDirectory: true)
            try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
            let file = memoryDir.appendingPathComponent("ok.md")
            try "tilde path".write(to: file, atomically: true, encoding: .utf8)

            // Provider resolves ~/ relative to its injected homeDirectory.
            let relative = "~/.claude/projects/my-proj/memory/ok.md"
            let response = try await provider.memoryFileContent(
                EngramServiceMemoryFileContentRequest(path: relative)
            )
            XCTAssertEqual(response.content, "tilde path")
        }
    }

    /// SEC-M2: open path must use O_NOFOLLOW (source contract + symlink rejection).
    func testMemoryFileContentUsesNoFollowOpen_repro() throws {
        let source = try String(
            contentsOfFile: "\(Self.repoRoot)/macos/EngramService/Core/EngramServiceReadProvider.swift",
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("O_NOFOLLOW"),
            "SEC-M2: memoryFileContent must open with O_NOFOLLOW"
        )
        XCTAssertTrue(
            source.contains("readRegularFileNoFollow"),
            "SEC-M2: dedicated no-follow reader must be used"
        )
        XCTAssertFalse(
            source.contains("String(contentsOf: standardized, encoding: .utf8)"),
            "SEC-M2: must not use check-then-String(contentsOf:) open"
        )
    }

    private static var repoRoot: String {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, url.lastPathComponent != "macos" {
            url.deleteLastPathComponent()
        }
        url.deleteLastPathComponent()
        return url.path
    }
}

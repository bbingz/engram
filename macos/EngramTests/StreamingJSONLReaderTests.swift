// macos/EngramTests/StreamingJSONLReaderTests.swift
import XCTest
@testable import Engram

final class StreamingJSONLReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helper

    private func fixturePath(_ name: String) -> String {
        Bundle(for: type(of: self)).path(forResource: "test-fixtures/sessions/\(name)", ofType: nil)
            ?? "/Users/bing/-Code-/coding-memory/test-fixtures/sessions/\(name)"
    }

    private func writeTempFile(_ name: String, content: String) -> String {
        let path = tempDir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: content.data(using: .utf8))
        return path
    }

    private func writeTempFile(_ name: String, data: Data) -> String {
        let path = tempDir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    // MARK: - Tests

    /// 1. Read well-formed JSONL — verify line count matches
    func testReadWellFormedJSONL() throws {
        let path = fixturePath("valid.jsonl")
        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil for existing file")
            return
        }
        defer { reader.close() }

        let lines = Array(reader)
        XCTAssertEqual(lines.count, 5, "valid.jsonl has 5 JSON lines")
        // Each line should be parseable JSON
        for line in lines {
            let data = line.data(using: .utf8)!
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    /// 2. UTF-8/CJK handling — Chinese, Japanese, Korean characters preserved
    func testCJKHandling() throws {
        let path = fixturePath("cjk.jsonl")
        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil for existing file")
            return
        }
        defer { reader.close() }

        let lines = Array(reader)
        XCTAssertEqual(lines.count, 3, "cjk.jsonl has 3 lines")
        XCTAssertTrue(lines[0].contains("你好世界"), "Chinese content preserved")
        XCTAssertTrue(lines[1].contains("こんにちは"), "Japanese content preserved")
        XCTAssertTrue(lines[2].contains("안녕하세요"), "Korean content preserved")
    }

    /// 3. Empty file yields 0 lines
    func testEmptyFileYieldsZeroLines() throws {
        let path = fixturePath("empty.jsonl")
        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil for existing empty file")
            return
        }
        defer { reader.close() }

        let lines = Array(reader)
        XCTAssertEqual(lines.count, 0, "Empty file should yield no lines")
    }

    /// 4. File not found returns nil
    func testFileNotFoundReturnsNil() throws {
        let reader = StreamingJSONLReader(filePath: "/nonexistent/path/to/file.jsonl")
        XCTAssertNil(reader, "Reader should be nil when file does not exist")
    }

    /// 5. Malformed lines are still returned (reader yields raw strings, not parsed JSON)
    func testMalformedLinesStillReturned() throws {
        let path = fixturePath("mixed.jsonl")
        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil")
            return
        }
        defer { reader.close() }

        let lines = Array(reader)
        // mixed.jsonl has 5 non-empty lines: 3 valid JSON + 2 malformed
        XCTAssertEqual(lines.count, 5, "All 5 non-empty lines should be yielded, including malformed ones")
    }

    /// 6. Long lines exceeding maxLineLength are skipped
    func testLongLinesSkipped() throws {
        // Create a file with one short line and one line exceeding 100 bytes
        let shortLine = "{\"ok\":true}"
        let longLine = String(repeating: "x", count: 200)
        let content = shortLine + "\n" + longLine + "\n"
        let path = writeTempFile("long-lines.jsonl", content: content)

        guard let reader = StreamingJSONLReader(filePath: path, maxLineLength: 100) else {
            XCTFail("Reader should not be nil")
            return
        }
        defer { reader.close() }

        let lines = Array(reader)
        XCTAssertEqual(lines.count, 1, "Only the short line should be returned")
        XCTAssertEqual(lines.first, shortLine)
    }

    /// 7. Partial last line (no trailing newline) is still returned
    func testPartialLastLineReturned() throws {
        let path = fixturePath("no-trailing-newline.jsonl")
        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil")
            return
        }
        defer { reader.close() }

        let lines = Array(reader)
        XCTAssertEqual(lines.count, 1, "File with one line and no trailing newline should yield 1 line")
        XCTAssertTrue(lines[0].contains("no newline at end"))
    }

    /// 8. Breaking mid-sequence and closing does not crash
    func testBreakMidSequenceAndClose() throws {
        let path = fixturePath("valid.jsonl")
        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil")
            return
        }

        // Read only the first line then break
        var count = 0
        for _ in reader {
            count += 1
            if count == 1 { break }
        }
        XCTAssertEqual(count, 1)
        reader.close()
        // No crash means success
    }

    /// 9. close() is idempotent — calling multiple times does not crash
    func testCloseIdempotent() throws {
        let path = fixturePath("valid.jsonl")
        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil")
            return
        }

        reader.close()
        reader.close()
        reader.close()
        // No crash = pass
    }

    /// 10. Empty lines (whitespace only) are skipped
    func testEmptyLinesSkipped() throws {
        let content = "{\"a\":1}\n\n   \n{\"b\":2}\n\n"
        let path = writeTempFile("empty-lines.jsonl", content: content)

        guard let reader = StreamingJSONLReader(filePath: path) else {
            XCTFail("Reader should not be nil")
            return
        }
        defer { reader.close() }

        let lines = Array(reader)
        XCTAssertEqual(lines.count, 2, "Only non-empty lines should be returned")
        XCTAssertTrue(lines[0].contains("\"a\""))
        XCTAssertTrue(lines[1].contains("\"b\""))
    }
}

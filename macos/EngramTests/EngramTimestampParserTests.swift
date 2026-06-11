import XCTest
@testable import Engram

final class EngramTimestampParserTests: XCTestCase {
    func testParsesWholeSecondISO8601Timestamp() throws {
        let date = try XCTUnwrap(EngramTimestampParser.date(from: "2026-06-08T16:12:54Z"))
        XCTAssertEqual(EngramTimestampParser.isoString(from: date), "2026-06-08T16:12:54Z")
    }

    func testParsesMillisecondISO8601Timestamp() throws {
        let date = try XCTUnwrap(EngramTimestampParser.date(from: "2026-02-27T07:23:28.782Z"))
        XCTAssertEqual(EngramTimestampParser.isoString(from: date), "2026-02-27T07:23:28Z")
    }

    func testParsesMicrosecondISO8601Timestamp() throws {
        let date = try XCTUnwrap(EngramTimestampParser.date(from: "2026-02-27T07:23:28.782123Z"))
        XCTAssertEqual(EngramTimestampParser.isoString(from: date), "2026-02-27T07:23:28Z")
    }

    func testParsesSQLiteDatetimeTimestampAsUTC() throws {
        let date = try XCTUnwrap(EngramTimestampParser.date(from: "2026-03-06 02:22:48"))
        XCTAssertEqual(EngramTimestampParser.isoString(from: date), "2026-03-06T02:22:48Z")
    }
}

// macos/EngramTests/ThemeTests.swift
import XCTest
import SwiftUI
@testable import Engram

private let expectedLocalTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    formatter.timeZone = .current
    return formatter
}()

final class ThemeTests: XCTestCase {

    // MARK: - Color constants

    func testAccentColorConstantsAreNotNil() {
        // Static color constants should all be non-nil Color values
        let colors: [Color] = [
            Theme.accent,
            Theme.green,
            Theme.orange,
            Theme.red,
            Theme.gray,
            Theme.primaryText,
            Theme.secondaryText,
            Theme.tertiaryText
        ]
        for color in colors {
            XCTAssertNotNil(color)
        }
    }

    func testAdaptiveColorConstantsAreNotNil() {
        // NSColor-backed adaptive colors should resolve
        let colors: [Color] = [
            Theme.background,
            Theme.surface,
            Theme.border,
            Theme.surfaceHighlight,
            Theme.inputBackground,
            Theme.sidebarSelection,
            Theme.sidebarSelectedText
        ]
        for color in colors {
            XCTAssertNotNil(color)
        }
    }

    // MARK: - formatTimestamp

    func testFormatTimestampExtractsTimeFromISO8601() {
        let timestamp = "2026-03-20T14:30:45Z"
        let result = formatTimestamp(timestamp)
        let date = ISO8601DateFormatter().date(from: timestamp)

        XCTAssertEqual(result, date.map { expectedLocalTimeFormatter.string(from: $0) })
    }

    func testFormatTimestampWithMilliseconds() {
        let timestamp = "2026-03-20T14:30:45.123Z"
        let result = formatTimestamp(timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp)

        XCTAssertEqual(result, date.map { expectedLocalTimeFormatter.string(from: $0) })
    }

    func testFormatTimestampHandlesMalformedInput() {
        // No "T" in the string: falls back to suffix(8)
        let result = formatTimestamp("12345678abcdefgh")
        XCTAssertEqual(result, "abcdefgh")
        // suffix(8) of "12345678abcdefgh" = "abcdefgh"
    }

    func testFormatTimestampWithShortInput() {
        // Input shorter than 8 chars: suffix(8) returns entire string
        let result = formatTimestamp("short")
        XCTAssertEqual(result, "short")
    }
}

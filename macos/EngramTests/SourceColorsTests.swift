// macos/EngramTests/SourceColorsTests.swift
import XCTest
import SwiftUI
@testable import Engram

final class SourceColorsTests: XCTestCase {

    private var allSources: [String] {
        SourceCatalog.all.map(\.id) + ["antigravity-legacy"]
    }

    func testAllKnownSourcesReturnNonNilColor() {
        for source in allSources {
            let color = SourceColors.color(for: source)
            // Color initializer always succeeds, so just verify we get one
            XCTAssertNotNil(color, "Color for \(source) should not be nil")
        }
    }

    func testUnknownSourceReturnsFallbackColor() {
        let unknown = SourceColors.color(for: "totally-unknown-tool")
        let fallback = Color(hex: 0x8E8E93)
        XCTAssertEqual(
            unknown.description, fallback.description,
            "Unknown source should use gray fallback"
        )
    }

    func testSameSourceReturnsSameColor() {
        let first = SourceColors.color(for: "claude-code")
        let second = SourceColors.color(for: "claude-code")
        XCTAssertEqual(
            first.description, second.description,
            "Same source should always return the same color"
        )
    }

    func testAllSourceNamesCovered() {
        let catalogIDs = Set(SourceCatalog.all.map(\.id))
        let sourceIDs = Set(SourceName.allCases.map(\.rawValue))
        XCTAssertEqual(catalogIDs, sourceIDs)
        XCTAssertEqual(allSources.count, SourceCatalog.all.count + 1)

        for source in allSources {
            let label = SourceColors.label(for: source)
            XCTAssertFalse(label.isEmpty, "Label for \(source) should not be empty")
        }
    }

    func testUnknownSourceLabelReturnsRawString() {
        let label = SourceColors.label(for: "mystery-tool")
        XCTAssertEqual(label, "mystery-tool", "Unknown source label should return the source string as-is")
    }
}

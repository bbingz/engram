import XCTest
import SwiftUI
@testable import Engram

/// Row 19 / 31 pure helpers for uiux-polish-a11y (no ViewInspector).
final class TranscriptAccessibilityTests: XCTestCase {
    // row 19: prev/next VoiceOver labels must be type-specific.
    func testChipNavLabelsAreTypeSpecific() {
        let prevUser = MessageTypeChip.chipNavLabel(.prev, type: .user)
        let prevTool = MessageTypeChip.chipNavLabel(.prev, type: .toolCall)
        XCTAssertNotEqual(prevUser, prevTool)
        XCTAssertTrue(prevUser.contains(MessageType.user.label))
        XCTAssertTrue(prevTool.contains(MessageType.toolCall.label))
        XCTAssertEqual(
            MessageTypeChip.chipNavLabel(.next, type: .thinking),
            "Next \(MessageType.thinking.label)"
        )
    }

    // row 31: Theme.scaledFontSize is monotonic in DynamicTypeSize.
    func testScaledFontSizeIsMonotonic() {
        let base: CGFloat = 14
        let categories: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
        ]
        var previous = Theme.scaledFontSize(base: base, category: categories[0])
        for category in categories.dropFirst() {
            let size = Theme.scaledFontSize(base: base, category: category)
            XCTAssertGreaterThanOrEqual(
                size, previous,
                "scaled size must not shrink from \(previous) to \(size) for \(category)"
            )
            previous = size
        }
        XCTAssertEqual(Theme.scaledFontSize(base: base, category: .large), base, accuracy: 0.01)
    }
}

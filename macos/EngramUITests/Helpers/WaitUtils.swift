import XCTest

extension XCUIApplication {
    /// Find an element by accessibility identifier regardless of its type in the accessibility tree.
    /// SwiftUI maps views to different XCUIElement types depending on the view kind
    /// (e.g., ScrollView -> scrollViews, VStack -> groups, Button -> buttons).
    /// This helper avoids guessing the type.
    func element(id identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }
}

extension XCUIElement {
    /// Wait for element to exist and be hittable
    @discardableResult
    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        waitForExistence(timeout: timeout) && isHittable
    }
}

extension XCTestCase {
    /// Wait for data to load — checks that a specific element appears
    func waitForDataLoad(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let exists = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(exists, "Element \(element.identifier) did not appear within \(timeout)s")
    }
}

extension XCUIElement {
    /// Scroll an element into view within its nearest scrollable ancestor.
    /// - Parameters:
    ///   - scrollView: The scroll view to scroll within. If nil, uses the app's first scrollView.
    ///   - maxAttempts: Maximum scroll gestures before giving up.
    ///   - deltaY: Vertical scroll delta per attempt (negative = scroll down).
    func scrollToVisible(
        in scrollView: XCUIElement,
        maxAttempts: Int = 10,
        deltaY: CGFloat = -150
    ) {
        guard exists else { return }
        for _ in 0..<maxAttempts {
            if isHittable { return }
            scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
        }
    }
}

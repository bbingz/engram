import XCTest

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

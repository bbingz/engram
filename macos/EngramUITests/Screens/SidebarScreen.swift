import XCTest

struct SidebarScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "sidebar") }
    var themeToggle: XCUIElement { app.element(id: "sidebar_themeToggle") }
    var settingsItem: XCUIElement { app.element(id: "sidebar_item_settings") }

    // MARK: - Navigation

    /// All known sidebar screen raw values (matches Screen.rawValue)
    static let pages = [
        "home", "search", "sessions", "timeline", "activity",
        "observability", "projects", "sourcePulse", "repos",
        "workGraph", "skills", "agents", "memory", "hooks"
    ]

    func item(for page: String) -> XCUIElement {
        app.element(id: "sidebar_item_\(page)")
    }

    func navigateTo(_ page: String) {
        let button = item(for: page)
        XCTAssertTrue(button.waitForExistence(timeout: 10),
                      "Sidebar item '\(page)' not found")

        // Bottom sidebar items may be below the visible scroll area in small windows.
        // Scroll them into view before clicking.
        if !button.isHittable {
            button.scrollToVisible(in: container)
        }

        button.click()
    }

    func allItems() -> [XCUIElement] {
        Self.pages.map { item(for: $0) }
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}

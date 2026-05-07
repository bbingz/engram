import XCTest

struct SettingsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.element(id: "settings_container") }

    // MARK: - Sections

    static let sectionNames = ["general", "ai", "sources", "network", "advanced", "about"]

    var generalSection: XCUIElement { app.element(id: "settings_section_general") }
    var aiSection: XCUIElement { app.element(id: "settings_section_ai") }
    var sourcesSection: XCUIElement { app.element(id: "settings_section_sources") }
    var networkSection: XCUIElement { app.element(id: "settings_section_network") }
    var advancedSection: XCUIElement { app.element(id: "settings_section_advanced") }
    var aboutSection: XCUIElement { app.element(id: "settings_section_about") }

    func navItem(named name: String) -> XCUIElement {
        app.element(id: "settings_nav_\(name)")
    }

    func section(named name: String) -> XCUIElement {
        app.element(id: "settings_section_\(name)")
    }

    func navigateToSection(named name: String) {
        let item = navItem(named: name)
        if item.waitForExistence(timeout: 3) {
            item.click()
        }
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}

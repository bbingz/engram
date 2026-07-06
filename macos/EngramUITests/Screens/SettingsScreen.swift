import XCTest

struct SettingsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.group(id: "settings_container") }

    // MARK: - Sections

    static let sectionNames = ["general", "ai", "sources", "advanced", "about"]

    var generalSection: XCUIElement { app.group(id: "settings_section_general") }
    var aiSection: XCUIElement { app.group(id: "settings_section_ai") }
    var sourcesSection: XCUIElement { app.group(id: "settings_section_sources") }
    var advancedSection: XCUIElement { app.group(id: "settings_section_advanced") }
    var aboutSection: XCUIElement { app.group(id: "settings_section_about") }

    func navItem(named name: String) -> XCUIElement {
        app.button(id: "settings_nav_\(name)")
    }

    func section(named name: String) -> XCUIElement {
        app.group(id: "settings_section_\(name)")
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

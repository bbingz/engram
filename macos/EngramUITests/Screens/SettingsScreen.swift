import XCTest

struct SettingsScreen {
    let app: XCUIApplication

    // MARK: - Elements

    var container: XCUIElement { app.otherElements["settings_container"] }

    // MARK: - Sections

    static let sectionNames = ["general", "ai", "sources", "network", "about"]

    var generalSection: XCUIElement { app.otherElements["settings_section_general"] }
    var aiSection: XCUIElement { app.otherElements["settings_section_ai"] }
    var sourcesSection: XCUIElement { app.otherElements["settings_section_sources"] }
    var networkSection: XCUIElement { app.otherElements["settings_section_network"] }
    var aboutSection: XCUIElement { app.otherElements["settings_section_about"] }

    func section(named name: String) -> XCUIElement {
        app.otherElements["settings_section_\(name)"]
    }

    // MARK: - Waits

    func waitForLoad(timeout: TimeInterval = 5) {
        _ = container.waitForExistence(timeout: timeout)
    }
}

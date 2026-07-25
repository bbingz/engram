import XCTest
@testable import Engram

/// Source-contract greps for uiux-polish Parts B/C/D call-site wiring.
final class UIUXPolishWiringTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testLoadFailureBannersCarryRetryAction() throws {
        for path in [
            "macos/Engram/Views/Pages/SessionsPageView.swift",
            "macos/Engram/Views/Workspace/ReposView.swift",
            "macos/Engram/Views/Pages/SourcePulseView.swift",
            "macos/Engram/Views/Pages/TimelinePageView.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(
                text.contains("action: (\"Retry\""),
                "\(path) load-failure banner must pass Retry action"
            )
            XCTAssertTrue(
                text.contains("ServiceErrorPresenter.displayMessage(for: error)"),
                "\(path) catches must route through ServiceErrorPresenter"
            )
        }
    }

    func testSidebarNoLongerPinsMaxWidth160() throws {
        let sidebar = try source("macos/Engram/Views/SidebarView.swift")
        XCTAssertFalse(
            sidebar.contains("maxWidth: 160"),
            "sidebar must not hard-pin maxWidth: 160 once Dynamic Type scales width"
        )
        XCTAssertTrue(sidebar.contains("@ScaledMetric"))
        XCTAssertTrue(sidebar.contains("navigationSplitViewColumnWidth"))
        XCTAssertTrue(sidebar.contains("scaledFont"))
    }

    func testTranscriptBodyComposesScaledFontSize() throws {
        for path in [
            "macos/Engram/Views/Transcript/ColorBarMessageView.swift",
            "macos/Engram/Views/ContentSegmentViews.swift",
            "macos/Engram/Views/Transcript/ToolCallView.swift",
            "macos/Engram/Views/Transcript/ToolResultView.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(
                text.contains("Theme.scaledFontSize(base: fontSize"),
                "\(path) must compose Dynamic Type with contentFontSize"
            )
        }
    }
}

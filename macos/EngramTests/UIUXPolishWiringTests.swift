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

    /// The check above only proves each file mentions the scaled size somewhere.
    /// Assistant and code messages render through SegmentedMessageView, so the
    /// scaled value has to survive two more hops: the routing decision, and the
    /// argument each segment view is actually handed. Passing the raw `fontSize`
    /// to one segment would stop that segment scaling while every file-level
    /// assertion kept passing.
    func testSegmentedTranscriptPathCarriesScaledFontSizeToEverySegment() throws {
        let colorBar = try source("macos/Engram/Views/Transcript/ColorBarMessageView.swift")
        let routeStart = try XCTUnwrap(colorBar.range(of: "static func usesSegmentedView"))
        let routeEnd = try XCTUnwrap(
            colorBar.range(of: "}", range: routeStart.upperBound..<colorBar.endIndex)
        )
        let route = String(colorBar[routeStart.upperBound..<routeEnd.upperBound])
        for role in ["assistant", "code"] {
            XCTAssertTrue(
                route.contains(".\(role)"),
                "\(role) messages must route to SegmentedMessageView, which owns the scaling"
            )
        }

        let segments = try source("macos/Engram/Views/ContentSegmentViews.swift")
        let bodyStart = try XCTUnwrap(segments.range(of: "ForEach(Array(displaySegments.enumerated())"))
        let bodyEnd = try XCTUnwrap(
            segments.range(of: ".task(id: content)", range: bodyStart.upperBound..<segments.endIndex)
        )
        let body = String(segments[bodyStart.upperBound..<bodyEnd.lowerBound])
        XCTAssertFalse(
            body.contains("fontSize: fontSize"),
            "every segment view must be handed effectiveFontSize, not the unscaled fontSize"
        )
        XCTAssertEqual(
            body.components(separatedBy: "fontSize: effectiveFontSize").count - 1,
            body.components(separatedBy: "fontSize:").count - 1,
            "a segment view is being handed some other font size"
        )
    }
}

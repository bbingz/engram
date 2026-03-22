import XCTest

class ScreenshotCapture {
    static let outputDir: String = {
        ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"]
            ?? NSTemporaryDirectory() + "engram-screenshots"
    }()

    private static var manifestEntries: [[String: Any]] = []
    private static var hasCleanedUp = false

    /// Call once at start of test run to clear stale screenshots.
    static func cleanOutputDir() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true
        let fm = FileManager.default
        if fm.fileExists(atPath: outputDir) {
            try? fm.removeItem(atPath: outputDir)
        }
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: outputDir + "/diffs", withIntermediateDirectories: true)
        manifestEntries = []
    }

    static func capture(name: String, app: XCUIApplication, screen: String, test: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let path = "\(outputDir)/\(name).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))

        let entry: [String: Any] = [
            "name": name,
            "screen": screen,
            "test": test,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "size": ["width": Int(screenshot.image.size.width), "height": Int(screenshot.image.size.height)],
            "scale": Int(NSScreen.main?.backingScaleFactor ?? 2)
        ]
        manifestEntries.append(entry)
        writeManifest()
    }

    private static func writeManifest() {
        let manifest: [String: Any] = [
            "screenshots": manifestEntries,
            "environment": [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "scheme": "EngramUITests"
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: "\(outputDir)/test-manifest.json"))
        }
    }
}

/// Register as principal class to clean screenshots once per test suite.
@objc(ScreenshotTestObserver)
class ScreenshotTestObserver: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }
    func testBundleWillStart(_ testBundle: Bundle) {
        ScreenshotCapture.cleanOutputDir()
    }
}

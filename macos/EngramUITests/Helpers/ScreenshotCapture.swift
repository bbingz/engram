import XCTest

class ScreenshotCapture {
    static let outputDir: String = {
        // Check env var first
        if let envDir = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !envDir.isEmpty {
            return envDir
        }
        // XCUITest runner is sandboxed — use NSTemporaryDirectory() which is inside the sandbox
        return NSTemporaryDirectory() + "engram-screenshots"
    }()

    /// The actual resolved output directory — read this after tests to find screenshots
    static var resolvedOutputDir: String { outputDir }

    private static var manifestEntries: [[String: Any]] = []
    private static var hasCleanedUp = false

    /// Call once at start of test run to clear stale screenshots.
    static func cleanOutputDir() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true
        NSLog("ScreenshotCapture: outputDir = \(outputDir)")
        let fm = FileManager.default
        if fm.fileExists(atPath: outputDir) {
            try? fm.removeItem(atPath: outputDir)
        }
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: outputDir + "/diffs", withIntermediateDirectories: true)
        manifestEntries = []
    }

    static func capture(name: String, app: XCUIApplication, screen: String, test: String) {
        // Ensure output directory exists (in case observer didn't fire)
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputDir) {
            do {
                try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
                NSLog("ScreenshotCapture: created dir \(outputDir)")
            } catch {
                NSLog("ScreenshotCapture: failed to create dir \(outputDir): \(error)")
                return
            }
        }

        // Use app screenshot (captures the app window)
        let screenshot = app.screenshot()
        let filePath = "\(outputDir)/\(name).png"
        do {
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: filePath))
            NSLog("ScreenshotCapture: wrote \(filePath) (\(screenshot.pngRepresentation.count) bytes)")
        } catch {
            NSLog("ScreenshotCapture: failed to write \(filePath): \(error)")
        }

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

import XCTest
@testable import EngramRemoteServerCore

/// M14: HEAD probes must not decrypt full object/manifest payloads.
final class ArchiveHeadExistenceTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testHeadRoutesUseExistenceOnlyAPIs_repro() throws {
        let routes = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/EngramRemoteServer/Core/ArchiveRoutes.swift"),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: repoRoot.appendingPathComponent("macos/EngramRemoteServer/Core/ArchiveStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(store.contains("func hasObject(digest:"), "M14: hasObject API required")
        XCTAssertTrue(store.contains("func hasManifest(digest:"), "M14: hasManifest API required")
        XCTAssertTrue(routes.contains("store.hasObject(digest:"), "M14: HEAD objects uses hasObject")
        XCTAssertTrue(routes.contains("store.hasManifest(digest:"), "M14: HEAD manifests uses hasManifest")
        XCTAssertTrue(
            routes.contains("HEAD must not decrypt full content")
                || routes.contains("store.hasObject(digest:"),
            "M14: HEAD path must not rely solely on getObject decrypt"
        )
    }
}

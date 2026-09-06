import Foundation
import MachO
import XCTest

final class CollectorTargetDependencyTests: XCTestCase {
    private let expectedSources: Set<String> = [
        "EngramCaptureShared/ExactSourceCapturer.swift",
        "EngramCaptureShared/ImmutableArchiveCAS.swift",
        "EngramCaptureShared/ArchiveCatalog.swift",
        "EngramCaptureShared/ArchiveCatalogMigrations.swift",
        "EngramCaptureShared/ArchiveLocatorClassifier.swift",
        "EngramCollectorCore/CollectorMachineIdentityReader.swift",
        "EngramCollectorCore/CollectorPrivacyProof.swift",
        "EngramCollectorCore/CollectorInventoryModels.swift",
        "EngramCollectorCore/CollectorInventoryStore.swift",
        "EngramCollectorCore/CollectorBootstrapWalker.swift",
        "EngramCollectorCore/CollectorPOSIXRootEnumerator.swift",
        "Shared/EngramCore/Adapters/SourceName.swift",
        "Shared/EngramCore/Adapters/SourceMetadataProjection.swift",
        "Shared/EngramCore/ArchiveV2/ArchiveHash.swift",
        "Shared/EngramCore/ArchiveV2/ArchiveCanonicalJSON.swift",
        "Shared/EngramCore/ArchiveV2/ArchiveModels.swift",
        "Shared/EngramCore/ArchiveV2/ArchiveSourceDescriptor.swift",
        "Shared/EngramCore/Database/SQLiteBusyDefaults.swift",
    ]

    func testCollectorSpecificationUsesOnlyExplicitCaptureSourcesAndGRDB() throws {
        let yaml = try String(contentsOf: macosRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        var inTarget = false
        var lines: [String] = []
        for line in yaml.components(separatedBy: .newlines) {
            if line == "  EngramCollectorCore:" { inTarget = true; continue }
            if inTarget, line.hasPrefix("  "), !line.hasPrefix("   "), !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if inTarget { lines.append(line) }
        }
        let prefix = "      - path: "
        let paths = lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        XCTAssertEqual(Set(paths), expectedSources)
        XCTAssertEqual(paths.count, expectedSources.count)
        XCTAssertEqual(lines.filter { $0.contains("- package:") }, ["      - package: GRDB"])
        XCTAssertEqual(lines.filter { $0.contains("product:") }, ["        product: GRDB-dynamic"])
        XCTAssertFalse(lines.contains { $0.contains("- target:") })
        XCTAssertTrue(lines.contains { $0.contains("ENGRAM_COLLECTOR_CORE") })
    }

    func testGeneratedCollectorTargetHasNoProductCoreDependencyOrHiddenSource() throws {
        let bytes = try Data(contentsOf: macosRoot.appendingPathComponent("Engram.xcodeproj/project.pbxproj"))
        let project = try XCTUnwrap(try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any])
        let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
        let target = try XCTUnwrap(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "EngramCollectorCore" })
        XCTAssertTrue((target["dependencies"] as? [String] ?? []).isEmpty)
        let products = try XCTUnwrap(target["packageProductDependencies"] as? [String])
        XCTAssertEqual(products.compactMap { objects[$0]?["productName"] as? String }, ["GRDB-dynamic"])
        let phases = try XCTUnwrap(target["buildPhases"] as? [String]).compactMap { objects[$0] }
        let sourcePhase = try XCTUnwrap(phases.first { $0["isa"] as? String == "PBXSourcesBuildPhase" })
        let files = try XCTUnwrap(sourcePhase["files"] as? [String])
        var paths: [String: String] = [:]
        func visit(_ identifier: String, prefix: String) {
            guard let object = objects[identifier] else { return }
            let component = object["path"] as? String ?? ""
            let path = [prefix, component].filter { !$0.isEmpty }.joined(separator: "/")
            if object["isa"] as? String == "PBXFileReference" { paths[identifier] = path }
            for child in object["children"] as? [String] ?? [] { visit(child, prefix: path) }
        }
        let rootObject = try XCTUnwrap(project["rootObject"] as? String)
        visit(try XCTUnwrap(objects[rootObject]?["mainGroup"] as? String), prefix: "")
        let sourcePaths = files.compactMap { objects[$0]?["fileRef"] as? String }.compactMap { paths[$0] }
        XCTAssertEqual(Set(sourcePaths), expectedSources)
        XCTAssertEqual(sourcePaths.count, expectedSources.count)
        let configurations = try XCTUnwrap(target["buildConfigurationList"] as? String)
        let configurationIDs = try XCTUnwrap(objects[configurations]?["buildConfigurations"] as? [String])
        for id in configurationIDs {
            let settings = try XCTUnwrap(objects[id]?["buildSettings"] as? [String: Any])
            XCTAssertTrue(String(describing: settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").contains("ENGRAM_COLLECTOR_CORE"))
        }
    }

    func testCollectorTestProcessDoesNotLoadProductCoreOrServiceFrameworks() {
        let forbidden = ["EngramCoreRead", "EngramCoreWrite", "EngramService", "EngramRemoteServer"]
        let images = (0..<_dyld_image_count()).compactMap { index in
            _dyld_get_image_name(index).map { String(cString: $0) }
        }
        XCTAssertTrue(images.contains { $0.contains("EngramCollectorCore.framework/") })
        for name in forbidden {
            XCTAssertFalse(images.contains { $0.contains("/\(name).framework/") || $0.contains("/\(name)Core.framework/") }, name)
        }
    }

    private var macosRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}

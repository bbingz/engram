import EngramCoreRead
import Foundation
import XCTest

final class ClaudeCodeProfileResolverTests: XCTestCase {
    private var fixtureRoot: URL!
    private var homeDirectory: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-claude-profiles-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = fixtureRoot.appendingPathComponent("home", isDirectory: true)
        settingsURL = homeDirectory.appendingPathComponent(".engram/settings.json")
        try FileManager.default.createDirectory(
            at: homeDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
        homeDirectory = nil
        settingsURL = nil
        try super.tearDownWithError()
    }

    func testMissingSettingsIncludesDefaultAndDiscoversAutomaticProfilesByDefault() throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        let automaticRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-sonnet"))

        let resolution = makeResolver().resolve()

        XCTAssertEqual(
            resolution.settings,
            ClaudeCodeProfileSettings(autoDiscover: true, customProjectsRoots: [])
        )
        XCTAssertNil(resolution.configurationError)
        XCTAssertEqual(resolution.profiles.map(\.projectsRoot), [
            defaultRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            automaticRoot.resolvingSymlinksInPath().standardizedFileURL.path,
        ].sorted())

        let defaultProfile = try XCTUnwrap(resolution.profiles.first { $0.origin == .default })
        XCTAssertEqual(defaultProfile.displayName, "Default")
        XCTAssertTrue(defaultProfile.available)
        XCTAssertTrue(defaultProfile.sourceReclamationAllowed)

        let automaticProfile = try XCTUnwrap(resolution.profiles.first { $0.origin == .automatic })
        XCTAssertEqual(automaticProfile.displayName, "sonnet")
        XCTAssertTrue(automaticProfile.available)
        XCTAssertTrue(automaticProfile.sourceReclamationAllowed)
    }

    func testAutomaticDiscoveryMatchesOnlyImmediateHomeChildrenWithImmediateProjectsDirectory() throws {
        let direct = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-direct"))
        _ = try makeProjectsRoot(
            parent: homeDirectory
                .appendingPathComponent("wrapper")
                .appendingPathComponent(".claude-nested")
        )
        try FileManager.default.createDirectory(
            at: homeDirectory.appendingPathComponent(".claude-without-projects"),
            withIntermediateDirectories: true
        )
        _ = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent("claude-not-hidden"))

        let automaticProfiles = makeResolver().resolve().profiles.filter { $0.origin == .automatic }

        XCTAssertEqual(
            automaticProfiles.map(\.projectsRoot),
            [direct.resolvingSymlinksInPath().standardizedFileURL.path]
        )
    }

    func testProfilesAndIdentifiersAreDeterministicAndPathSorted() throws {
        _ = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-zeta"))
        _ = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-alpha"))
        let customRoot = try makeProjectsRoot(parent: fixtureRoot.appendingPathComponent("custom-middle"))
        try writeSettings(autoDiscover: true, customProjectsRoots: [customRoot.path])

        let first = makeResolver().resolve()
        let second = makeResolver().resolve()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.profiles.map(\.projectsRoot), first.profiles.map(\.projectsRoot).sorted())
        XCTAssertEqual(Set(first.profiles.map(\.id)).count, first.profiles.count)
        for profile in first.profiles {
            XCTAssertTrue(profile.id.hasPrefix("\(profile.origin.rawValue)-"))
            let digest = String(profile.id.dropFirst(profile.origin.rawValue.count + 1))
            XCTAssertEqual(digest.utf8.count, 64)
            XCTAssertTrue(digest.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        }
    }

    func testCanonicalDuplicateRootsCollapseWithSafeOriginPrecedence() throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        let customParent = fixtureRoot.appendingPathComponent("linked-custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customParent, withIntermediateDirectories: true)
        let linkedProjects = customParent.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedProjects, withDestinationURL: defaultRoot)
        try writeSettings(autoDiscover: true, customProjectsRoots: [linkedProjects.path])

        let resolution = makeResolver().resolve()

        XCTAssertEqual(resolution.profiles.count, 1)
        XCTAssertEqual(resolution.profiles[0].origin, .default)
        XCTAssertEqual(
            resolution.profiles[0].projectsRoot,
            defaultRoot.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertTrue(resolution.profiles[0].sourceReclamationAllowed)
    }

    func testDefaultProjectsSymlinkEscapeRemainsIndexableButNotReclaimable() throws {
        let externalRoot = try makeProjectsRoot(
            parent: fixtureRoot.appendingPathComponent("external-default")
        )
        let defaultParent = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: defaultParent.appendingPathComponent("projects", isDirectory: true),
            withDestinationURL: externalRoot
        )

        let profile = try XCTUnwrap(makeResolver().resolve().profiles.first { $0.origin == .default })

        XCTAssertEqual(
            profile.projectsRoot,
            externalRoot.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertTrue(profile.available)
        XCTAssertFalse(profile.sourceReclamationAllowed)
    }

    func testAutomaticProjectsSymlinkEscapeRemainsIndexableButNotReclaimable() throws {
        let externalRoot = try makeProjectsRoot(
            parent: fixtureRoot.appendingPathComponent("external-automatic")
        )
        let automaticParent = homeDirectory.appendingPathComponent(".claude-escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: automaticParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: automaticParent.appendingPathComponent("projects", isDirectory: true),
            withDestinationURL: externalRoot
        )

        let profile = try XCTUnwrap(
            makeResolver().resolve().profiles.first { $0.origin == .automatic }
        )

        XCTAssertEqual(
            profile.projectsRoot,
            externalRoot.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertTrue(profile.available)
        XCTAssertFalse(profile.sourceReclamationAllowed)
    }

    func testMissingConfiguredRootRemainsVisibleButUnavailable() throws {
        let missingRoot = fixtureRoot
            .appendingPathComponent("missing-profile", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        try writeSettings(autoDiscover: true, customProjectsRoots: [missingRoot.path])

        let resolution = makeResolver().resolve()

        XCTAssertNil(resolution.configurationError)
        XCTAssertEqual(resolution.settings.customProjectsRoots, [missingRoot.standardizedFileURL.path])
        let profile = try XCTUnwrap(resolution.profiles.first { $0.origin == .custom })
        XCTAssertEqual(profile.displayName, "missing-profile")
        XCTAssertEqual(profile.projectsRoot, missingRoot.standardizedFileURL.path)
        XCTAssertFalse(profile.available)
        XCTAssertFalse(profile.sourceReclamationAllowed)
    }

    func testDisabledAutomaticDiscoveryStillIncludesDefaultRoot() throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        _ = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-disabled"))
        try writeSettings(autoDiscover: false, customProjectsRoots: [])

        let resolution = makeResolver().resolve()

        XCTAssertFalse(resolution.settings.autoDiscover)
        XCTAssertEqual(resolution.profiles.map(\.origin), [.default])
        XCTAssertEqual(
            resolution.profiles.map(\.projectsRoot),
            [defaultRoot.resolvingSymlinksInPath().standardizedFileURL.path]
        )
    }

    func testValidationAcceptsAtMost64CustomRoots() throws {
        var roots: [String] = []
        for index in 0..<65 {
            roots.append(
                try makeProjectsRoot(
                    parent: fixtureRoot.appendingPathComponent("custom-\(index)")
                ).path
            )
        }

        let validated = try makeResolver().validateCustomProjectsRoots(Array(roots.prefix(64)))

        XCTAssertEqual(validated.count, 64)
        XCTAssertThrowsError(try makeResolver().validateCustomProjectsRoots(roots))
    }

    func testValidationRejectsInvalidOrUnsafeRootsAndCanonicalDuplicates() throws {
        let validRoot = try makeProjectsRoot(parent: fixtureRoot.appendingPathComponent("valid"))
        let duplicateParent = fixtureRoot.appendingPathComponent("duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateParent, withIntermediateDirectories: true)
        let duplicateRoot = duplicateParent.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: duplicateRoot, withDestinationURL: validRoot)
        let archiveProjects = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".engram/archive-v2/profile")
        )
        let missingProjects = fixtureRoot
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let oversizedPath = "/" + String(repeating: "x", count: 4_096) + "/projects"

        XCTAssertThrowsError(try makeResolver().validateCustomProjectsRoots(["relative/projects"]))
        XCTAssertThrowsError(try makeResolver().validateCustomProjectsRoots([validRoot.deletingLastPathComponent().path]))
        XCTAssertThrowsError(try makeResolver().validateCustomProjectsRoots([missingProjects.path]))
        XCTAssertThrowsError(try makeResolver().validateCustomProjectsRoots([oversizedPath]))
        XCTAssertThrowsError(try makeResolver().validateCustomProjectsRoots([archiveProjects.path]))
        XCTAssertEqual(
            try makeResolver().validateCustomProjectsRoots([duplicateRoot.path]),
            [validRoot.resolvingSymlinksInPath().standardizedFileURL.path]
        )
        XCTAssertThrowsError(
            try makeResolver().validateCustomProjectsRoots([validRoot.path, duplicateRoot.path])
        )
    }

    func testValidationRejectsProjectsAliasWithNonProjectsCanonicalBasename() throws {
        let canonicalRoot = fixtureRoot.appendingPathComponent(
            "canonical-session-root",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: canonicalRoot,
            withIntermediateDirectories: true
        )
        let aliasParent = fixtureRoot.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
        let aliasRoot = aliasParent.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: aliasRoot,
            withDestinationURL: canonicalRoot
        )

        XCTAssertThrowsError(
            try makeResolver().validateCustomProjectsRoots([aliasRoot.path])
        )
    }

    func testInvalidSettingsReturnDefaultsWithFixedSymbolicError() throws {
        _ = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-auto"))
        try writeRawSettings([
            "claudeCodeProfiles": [
                "autoDiscover": "yes",
                "customProjectsRoots": [],
            ],
        ])

        let resolution = makeResolver().resolve()

        XCTAssertEqual(
            resolution.settings,
            ClaudeCodeProfileSettings(autoDiscover: true, customProjectsRoots: [])
        )
        XCTAssertEqual(resolution.configurationError, "invalid_claude_code_profiles")
        XCTAssertEqual(resolution.profiles.map(\.origin), [.automatic])
    }

    func testOversizedSettingsAreRejectedBeforeJSONParsing() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let oversized = Data(
            "{\"padding\":\"\(String(repeating: "x", count: 300_000))\"}".utf8
        )
        try oversized.write(to: settingsURL)

        let resolution = makeResolver().resolve()

        XCTAssertEqual(resolution.configurationError, "invalid_claude_code_profiles")
        XCTAssertEqual(
            resolution.settings,
            ClaudeCodeProfileSettings(autoDiscover: true, customProjectsRoots: [])
        )
    }

    private func makeResolver() -> ClaudeCodeProfileResolver {
        ClaudeCodeProfileResolver(homeDirectory: homeDirectory, settingsURL: settingsURL)
    }

    @discardableResult
    private func makeProjectsRoot(parent: URL) throws -> URL {
        let projects = parent.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return projects
    }

    private func writeSettings(autoDiscover: Bool, customProjectsRoots: [String]) throws {
        try writeRawSettings([
            "claudeCodeProfiles": [
                "autoDiscover": autoDiscover,
                "customProjectsRoots": customProjectsRoots,
            ],
        ])
    }

    private func writeRawSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: settingsURL)
    }
}

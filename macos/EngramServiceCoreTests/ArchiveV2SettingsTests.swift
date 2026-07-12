import Foundation
import XCTest
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class ArchiveV2SettingsTests: XCTestCase {
    func testReclamationDefaultsDisabledWithThirtyDayWindow() throws {
        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertEqual(settings.reclamation, .init(enabled: false, hotWindowDays: 30))
        XCTAssertNil(settings.reclamationConfigurationError)
    }

    func testReclamationAcceptsOnlySupportedHotWindowsAndFailsClosed() throws {
        for days in [30, 60, 90, 180] {
            try writeSettings([
                "archiveReclamation": ["enabled": true, "hotWindowDays": days],
            ])
            let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
            XCTAssertEqual(settings.reclamation, .init(enabled: true, hotWindowDays: days))
            XCTAssertNil(settings.reclamationConfigurationError)
        }

        for value: Any in [29, 31, 365, "30", true] {
            try writeSettings([
                "archiveReclamation": ["enabled": true, "hotWindowDays": value],
            ])
            let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
            XCTAssertEqual(settings.reclamation, .init(enabled: false, hotWindowDays: 30))
            XCTAssertEqual(settings.reclamationConfigurationError, .invalidHotWindowDays)
        }
    }

    func testInvalidReclamationDoesNotDisableValidRemoteReplication() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": [
                "enabled": true,
                "batchSize": 20,
                "replicas": [
                    ["id": "hq", "serverURL": "https://hq.tail.example.ts.net", "requireTLS": true],
                    ["id": "m1", "serverURL": "http://100.64.0.2:8787", "requireTLS": false],
                ],
            ],
            "archiveReclamation": ["enabled": true, "hotWindowDays": 90, "extra": true],
        ])
        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertTrue(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.configurationError)
        XCTAssertEqual(settings.reclamation, .init(enabled: false, hotWindowDays: 30))
        XCTAssertEqual(settings.reclamationConfigurationError, .invalidReclamationConfiguration)
    }
    private var root: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-archive-v2-settings-\(UUID().uuidString)", isDirectory: true)
        settingsURL = root.appendingPathComponent("nested/settings.json")
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testMissingSettingsDefaultsOffWithoutCreatingAnyPath() {
        let settings = ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: [:]
        )

        XCTAssertFalse(settings.exactArchiveEnabled)
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.remoteConfiguration)
        XCTAssertNil(settings.configurationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReadsExactTwoReplicaConfigurationWithDefaultBatchAndNormalizedExclusions() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": [
                "enabled": true,
                "replicas": [
                    ["id": "hq", "serverURL": "https://hq.tail.example.ts.net", "requireTLS": true],
                    ["id": "m1", "serverURL": "http://100.64.0.2:8787", "requireTLS": false],
                ],
                "excludedProjectRoots": ["/Users/bing/Work", "/Users/bing/Work"],
            ],
        ])

        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertTrue(settings.exactArchiveEnabled)
        XCTAssertTrue(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.configurationError)
        let remote = try XCTUnwrap(settings.remoteConfiguration)
        XCTAssertEqual(remote.batchSize, 20)
        XCTAssertEqual(remote.replicas.map(\.id), ["hq", "m1"])
        XCTAssertEqual(
            remote.replicas.map(\.serverURL),
            ["https://hq.tail.example.ts.net", "http://100.64.0.2:8787"]
        )
        XCTAssertEqual(remote.excludedProjectRoots, ["/Users/bing/Work"])
    }

    func testEnvironmentOverridesExactFlagAndRemoteObjectAtomically() throws {
        try writeSettings([
            "exactArchiveEnabled": false,
            "remoteArchiveV2": validRemoteObject(
                batchSize: 99,
                hqURL: "https://stored-hq.ts.net",
                m1URL: "https://stored-m1.ts.net"
            ),
        ])
        let override = try JSONSerialization.data(
            withJSONObject: validRemoteObject(
                batchSize: 7,
                hqURL: "https://override-hq.ts.net",
                m1URL: "https://override-m1.ts.net"
            ),
            options: [.sortedKeys]
        )

        let settings = ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: [
                "ENGRAM_EXACT_ARCHIVE_ENABLED": "true",
                "ENGRAM_REMOTE_ARCHIVE_V2_CONFIG_JSON": try XCTUnwrap(String(data: override, encoding: .utf8)),
            ]
        )

        XCTAssertTrue(settings.exactArchiveEnabled)
        XCTAssertTrue(settings.remoteReplicationEnabled)
        XCTAssertEqual(settings.remoteConfiguration?.batchSize, 7)
        XCTAssertEqual(
            settings.remoteConfiguration?.replicas.map(\.serverURL),
            ["https://override-hq.ts.net", "https://override-m1.ts.net"]
        )
    }

    func testMalformedEnvironmentRemoteOverrideDoesNotFallBackToStoredConfiguration() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": validRemoteObject(),
        ])

        let settings = ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: ["ENGRAM_REMOTE_ARCHIVE_V2_CONFIG_JSON": #"{"enabled":true}"#]
        )

        XCTAssertTrue(settings.exactArchiveEnabled, "remote failure must not disable local exact capture")
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.remoteConfiguration)
        XCTAssertEqual(settings.configurationError, .invalidReplicaSet)
    }

    func testMalformedInputsFailClosedWithSymbolicErrorsThatDoNotEchoValues() throws {
        let cases: [(String, [String: Any], ArchiveV2SettingsConfigurationError)] = [
            (
                "duplicate ids",
                validRemoteObject(replicas: [
                    ["id": "hq", "serverURL": "https://one.ts.net", "requireTLS": true],
                    ["id": "hq", "serverURL": "https://two.ts.net", "requireTLS": true],
                ]),
                .invalidReplicaSet
            ),
            (
                "duplicate canonical origins",
                validRemoteObject(replicas: [
                    ["id": "hq", "serverURL": "https://same.ts.net", "requireTLS": true],
                    ["id": "m1", "serverURL": "https://SAME.ts.net/", "requireTLS": true],
                ]),
                .duplicateReplicaOrigin
            ),
            (
                "invalid origin",
                validRemoteObject(replicas: [
                    ["id": "hq", "serverURL": "https://public.example.com/private-secret", "requireTLS": true],
                    ["id": "m1", "serverURL": "https://m1.ts.net", "requireTLS": true],
                ]),
                .invalidReplicaOrigin
            ),
            (
                "invalid root",
                validRemoteObject(excludedRoots: ["relative/private-secret"]),
                .invalidExcludedProjectRoot
            ),
            (
                "batch low",
                validRemoteObject(batchSize: 0),
                .invalidBatchSize
            ),
            (
                "batch high",
                validRemoteObject(batchSize: 101),
                .invalidBatchSize
            ),
        ]

        for (name, remote, expectedError) in cases {
            try writeSettings([
                "exactArchiveEnabled": true,
                "remoteArchiveV2": remote,
            ])
            let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
            XCTAssertTrue(settings.exactArchiveEnabled, name)
            XCTAssertFalse(settings.remoteReplicationEnabled, name)
            XCTAssertNil(settings.remoteConfiguration, name)
            XCTAssertEqual(settings.configurationError, expectedError, name)
            XCTAssertFalse(String(describing: settings.configurationError).contains("private-secret"), name)
        }
    }

    func testInvalidExactEnvironmentFlagFailsClosed() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": validRemoteObject(),
        ])

        let settings = ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: ["ENGRAM_EXACT_ARCHIVE_ENABLED": "sometimes/private-secret"]
        )

        XCTAssertFalse(settings.exactArchiveEnabled)
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.remoteConfiguration)
        XCTAssertEqual(settings.configurationError, .invalidExactArchiveFlag)
        XCTAssertFalse(String(describing: settings.configurationError).contains("private-secret"))
    }

    func testExactCaptureRemainsEnabledWhenStoredRemoteConfigurationIsInvalid() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": [
                "enabled": true,
                "replicas": [["id": "hq", "serverURL": "https://hq.ts.net", "requireTLS": true]],
            ],
        ])

        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertTrue(settings.exactArchiveEnabled)
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.remoteConfiguration)
        XCTAssertEqual(settings.configurationError, .invalidReplicaSet)
    }

    func testTokenLikeEnvironmentValuesAreNeverPartOfSettingsConfiguration() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": validRemoteObject(),
        ])
        let baseline = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        let withTokenLikeEnvironment = ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: [
                "ENGRAM_REMOTE_ARCHIVE_V2_HQ_TOKEN": "private-secret-hq",
                "ENGRAM_REMOTE_ARCHIVE_V2_M1_TOKEN": "private-secret-m1",
            ]
        )

        XCTAssertEqual(withTokenLikeEnvironment, baseline)
        XCTAssertFalse(String(describing: withTokenLikeEnvironment).contains("private-secret"))
    }

    func testStoredRemoteObjectRejectsUnknownTokenFieldWithoutEchoingIt() throws {
        var remote = validRemoteObject()
        remote["token"] = "private-secret"
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": remote,
            "unrelatedProductSetting": "may-remain-forward-compatible",
        ])

        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertTrue(settings.exactArchiveEnabled)
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.remoteConfiguration)
        XCTAssertEqual(settings.configurationError, .invalidRemoteConfiguration)
        XCTAssertFalse(String(describing: settings.configurationError).contains("private-secret"))
    }

    func testEnvironmentRemoteObjectRejectsUnknownReplicaSecretFieldAtomically() throws {
        var hq: [String: Any] = [
            "id": "hq",
            "serverURL": "https://override-hq.ts.net",
            "requireTLS": true,
        ]
        hq["password"] = "private-secret"
        let remote = validRemoteObject(replicas: [
            hq,
            ["id": "m1", "serverURL": "https://override-m1.ts.net", "requireTLS": true],
        ])
        let data = try JSONSerialization.data(withJSONObject: remote, options: [.sortedKeys])
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": validRemoteObject(),
        ])

        let settings = ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: [
                "ENGRAM_REMOTE_ARCHIVE_V2_CONFIG_JSON": try XCTUnwrap(String(data: data, encoding: .utf8)),
            ]
        )

        XCTAssertTrue(settings.exactArchiveEnabled)
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.remoteConfiguration)
        XCTAssertEqual(settings.configurationError, .invalidReplicaSet)
        XCTAssertFalse(String(describing: settings.configurationError).contains("private-secret"))
    }

    func testDisabledRemoteStillRejectsUnknownReplicaFieldsWhenDescriptorsArePresent() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": [
                "enabled": false,
                "replicas": [
                    [
                        "id": "hq",
                        "serverURL": "https://hq.ts.net",
                        "requireTLS": true,
                        "authHeader": "private-secret",
                    ],
                ],
            ],
        ])

        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertTrue(settings.exactArchiveEnabled)
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.remoteConfiguration)
        XCTAssertEqual(settings.configurationError, .invalidReplicaSet)
        XCTAssertFalse(String(describing: settings.configurationError).contains("private-secret"))
    }

    func testSettingsJSONRejectsNumericZeroAndOneForEveryBooleanField() throws {
        for numericBoolean in [0, 1] {
            try writeSettings([
                "exactArchiveEnabled": numericBoolean,
                "remoteArchiveV2": validRemoteObject(),
            ])
            var settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
            XCTAssertFalse(settings.exactArchiveEnabled, "exactArchiveEnabled=\(numericBoolean)")
            XCTAssertEqual(settings.configurationError, .invalidExactArchiveFlag)

            var remote = validRemoteObject()
            remote["enabled"] = numericBoolean
            try writeSettings([
                "exactArchiveEnabled": true,
                "remoteArchiveV2": remote,
            ])
            settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
            XCTAssertTrue(settings.exactArchiveEnabled)
            XCTAssertFalse(settings.remoteReplicationEnabled, "remote enabled=\(numericBoolean)")
            XCTAssertEqual(settings.configurationError, .invalidRemoteConfiguration)

            let hq: [String: Any] = [
                "id": "hq",
                "serverURL": "https://hq.ts.net",
                "requireTLS": numericBoolean,
            ]
            let m1: [String: Any] = [
                "id": "m1",
                "serverURL": "https://m1.ts.net",
                "requireTLS": true,
            ]
            try writeSettings([
                "exactArchiveEnabled": true,
                "remoteArchiveV2": validRemoteObject(replicas: [hq, m1]),
            ])
            settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
            XCTAssertTrue(settings.exactArchiveEnabled)
            XCTAssertFalse(settings.remoteReplicationEnabled, "requireTLS=\(numericBoolean)")
            XCTAssertEqual(settings.configurationError, .invalidReplicaSet)
        }
    }

    func testEnvironmentRemoteJSONRejectsNumericZeroAndOneForBooleanFields() throws {
        try writeSettings(["exactArchiveEnabled": true])

        for numericBoolean in [0, 1] {
            var remote = validRemoteObject()
            remote["enabled"] = numericBoolean
            var settings = try loadWithRemoteEnvironment(remote)
            XCTAssertTrue(settings.exactArchiveEnabled)
            XCTAssertFalse(settings.remoteReplicationEnabled, "remote enabled=\(numericBoolean)")
            XCTAssertEqual(settings.configurationError, .invalidRemoteConfiguration)

            remote = validRemoteObject(replicas: [
                ["id": "hq", "serverURL": "https://hq.ts.net", "requireTLS": numericBoolean],
                ["id": "m1", "serverURL": "https://m1.ts.net", "requireTLS": true],
            ])
            settings = try loadWithRemoteEnvironment(remote)
            XCTAssertTrue(settings.exactArchiveEnabled)
            XCTAssertFalse(settings.remoteReplicationEnabled, "requireTLS=\(numericBoolean)")
            XCTAssertEqual(settings.configurationError, .invalidReplicaSet)
        }
    }

    func testBooleanBatchSizeIsRejectedFromSettingsAndEnvironmentJSON() throws {
        for booleanBatch in [false, true] {
            var remote = validRemoteObject()
            remote["batchSize"] = booleanBatch
            try writeSettings([
                "exactArchiveEnabled": true,
                "remoteArchiveV2": remote,
            ])
            var settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
            XCTAssertTrue(settings.exactArchiveEnabled)
            XCTAssertFalse(settings.remoteReplicationEnabled, "stored batchSize=\(booleanBatch)")
            XCTAssertEqual(settings.configurationError, .invalidBatchSize)

            settings = try loadWithRemoteEnvironment(remote)
            XCTAssertTrue(settings.exactArchiveEnabled)
            XCTAssertFalse(settings.remoteReplicationEnabled, "env batchSize=\(booleanBatch)")
            XCTAssertEqual(settings.configurationError, .invalidBatchSize)
        }
    }

    func testProjectExclusionMatchesOnlyExactPathOrPathComponentDescendants() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": validRemoteObject(excludedRoots: ["/Users/bing/Work"]),
        ])
        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertTrue(settings.isProjectExcluded("/Users/bing/Work"))
        XCTAssertTrue(settings.isProjectExcluded("/Users/bing/Work/client/app"))
        XCTAssertFalse(settings.isProjectExcluded("/Users/bing/Workspace"))
        XCTAssertFalse(settings.isProjectExcluded("/Users/bing/Worktree"))
        XCTAssertFalse(settings.isProjectExcluded("relative/Work"))
        XCTAssertFalse(settings.isProjectExcluded("/Users/bing/Work/../Personal"))
        XCTAssertFalse(settings.isProjectExcluded("/Users/bing/Work\0/secret"))
    }

    func testAmbiguousExcludedRootsAreRejectedInsteadOfSilentlyNormalized() throws {
        for rootValue in ["/", "/Users/bing/Work/../Personal", "/Users//bing/Work", "/Users/bing/Work/", "/Users/bing/Work\0/secret"] {
            try writeSettings([
                "exactArchiveEnabled": true,
                "remoteArchiveV2": validRemoteObject(excludedRoots: [rootValue]),
            ])

            let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

            XCTAssertTrue(settings.exactArchiveEnabled, rootValue)
            XCTAssertFalse(settings.remoteReplicationEnabled, rootValue)
            XCTAssertEqual(settings.configurationError, .invalidExcludedProjectRoot, rootValue)
        }
    }

    func testRemoteDisabledDoesNotRequireReplicaDescriptors() throws {
        try writeSettings([
            "exactArchiveEnabled": true,
            "remoteArchiveV2": ["enabled": false],
        ])

        let settings = ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])

        XCTAssertTrue(settings.exactArchiveEnabled)
        XCTAssertFalse(settings.remoteReplicationEnabled)
        XCTAssertNil(settings.configurationError)
        XCTAssertEqual(settings.remoteConfiguration?.enabled, false)
        XCTAssertEqual(settings.remoteConfiguration?.batchSize, 20)
        XCTAssertEqual(settings.remoteConfiguration?.replicas, [])
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: settingsURL)
    }

    private func loadWithRemoteEnvironment(
        _ remote: [String: Any]
    ) throws -> ArchiveV2Settings {
        let data = try JSONSerialization.data(withJSONObject: remote, options: [.sortedKeys])
        return ArchiveV2Settings.load(
            settingsURL: settingsURL,
            environment: [
                "ENGRAM_REMOTE_ARCHIVE_V2_CONFIG_JSON": try XCTUnwrap(String(data: data, encoding: .utf8)),
            ]
        )
    }

    private func validRemoteObject(
        batchSize: Int? = nil,
        hqURL: String = "https://hq.ts.net",
        m1URL: String = "https://m1.ts.net",
        replicas: [[String: Any]]? = nil,
        excludedRoots: [String] = []
    ) -> [String: Any] {
        var object: [String: Any] = [
            "enabled": true,
            "replicas": replicas ?? [
                ["id": "hq", "serverURL": hqURL, "requireTLS": true],
                ["id": "m1", "serverURL": m1URL, "requireTLS": true],
            ],
            "excludedProjectRoots": excludedRoots,
        ]
        if let batchSize {
            object["batchSize"] = batchSize
        }
        return object
    }
}

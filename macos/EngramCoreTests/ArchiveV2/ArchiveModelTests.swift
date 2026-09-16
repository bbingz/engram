import EngramCoreRead
import XCTest

final class ArchiveModelTests: XCTestCase {
    private let captureDigest = String(repeating: "a", count: 64)
    private let sourceDigest = String(repeating: "b", count: 64)
    private let chunkDigest = String(repeating: "c", count: 64)
    private let manifestDigest = String(repeating: "d", count: 64)
    private let machineID = "123e4567-e89b-12d3-a456-426614174000"

    func testSHA256KnownVectorsAndValidation() {
        XCTAssertEqual(
            ArchiveV2Hash.sha256(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ArchiveV2Hash.sha256(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertTrue(ArchiveV2Hash.isValidSHA256(sourceDigest))
        XCTAssertFalse(ArchiveV2Hash.isValidSHA256(String(repeating: "A", count: 64)))
        XCTAssertFalse(ArchiveV2Hash.isValidSHA256(String(repeating: "a", count: 63)))
    }

    func testCanonicalManifestEncodingIsStableAndRoundTrips() throws {
        let manifest = try makeManifest()

        let encoded = try ArchiveCanonicalJSON.encode(manifest)

        let expected = "{\"captureID\":\"\(captureDigest)\",\"capturedAt\":\"2026-07-11T00:00:00.000Z\",\"chunkSize\":8388608,\"chunks\":[{\"ordinal\":0,\"rawByteCount\":5,\"rawSHA256\":\"\(chunkDigest)\"}],\"generation\":{\"ctimeNs\":6,\"device\":1,\"inode\":2,\"mode\":33188,\"mtimeNs\":5,\"size\":5},\"locator\":\"/tmp/source.jsonl\",\"machineID\":\"\(machineID)\",\"rawByteCount\":5,\"replayLayout\":{\"relativePaths\":[\"sessions/session.jsonl\"],\"strategy\":\"singleFile\"},\"schemaVersion\":1,\"sessionID\":\"session-1\",\"source\":\"codex\",\"wholeSourceSHA256\":\"\(sourceDigest)\"}"
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), expected)
        XCTAssertEqual(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: encoded),
            manifest
        )
    }

    func testVSCodeFrozenWorkspaceSchemaSevenRoundTripsExactExternalBytes() throws {
        let bytes = try vscodeContextManifestBytes()
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertEqual(manifest.schemaVersion, 7)
        XCTAssertEqual(manifest.source, "vscode")
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(manifest), bytes)
    }

    func testVSCodeFrozenConfigurationAbsenceRoundTripsWithoutInventingBytes() throws {
        let bytes = try vscodeContextManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            var context = layout["vscodeWorkspaceContext"] as! [String: Any]
            context.removeValue(forKey: "configurationData")
            context.removeValue(forKey: "configurationSHA256")
            context.removeValue(forKey: "configurationGeneration")
            layout["vscodeWorkspaceContext"] = context
            object["replayLayout"] = layout
        }
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)), bytes)
    }

    func testVSCodeWorkspaceContextCannotBeDroppedBySchemaDowngradeOrSourceSwap() throws {
        for version in 1...6 {
            let bytes = try vscodeContextManifestBytes { $0["schemaVersion"] = version }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), "schema \(version)")
        }
        for (key, value) in [("source", "gemini-cli"), ("sessionID", "bound"), ("locator", "/source/other/chatSessions/session.jsonl")] {
            let bytes = try vscodeContextManifestBytes { $0[key] = value }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
    }

    func testVSCodeExternalConfigurationRejectsInvalidBytesAndProvenance() throws {
        for (key, value) in [("kind", "other" as Any), ("configurationLocator", "relative.code-workspace"),
                            ("configurationLocator", "/source/../other"),
                            ("configurationSHA256", String(repeating: "e", count: 64)),
                            ("configurationData", Data("tampered".utf8).base64EncodedString())] {
            let bytes = try vscodeContextManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                var context = layout["vscodeWorkspaceContext"] as! [String: Any]
                context[key] = value
                layout["vscodeWorkspaceContext"] = context
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
        for key in ["configurationLocator", "configurationSHA256", "configurationData", "configurationGeneration"] {
            let bytes = try vscodeContextManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                var context = layout["vscodeWorkspaceContext"] as! [String: Any]
                context.removeValue(forKey: key)
                layout["vscodeWorkspaceContext"] = context
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
    }

    func testVSCodeContextBindsFrozenWorkspaceReferenceAndFolderPrecedence() throws {
        let context = try ArchiveVSCodeWorkspaceContext(configurationLocator: "/original/project.code-workspace")
        try context.validateWorkspaceData(Data(#"{"configuration":"file://localhost/original/project.code-workspace"}"#.utf8))
        XCTAssertThrowsError(try context.validateWorkspaceData(nil))
        XCTAssertThrowsError(try context.validateWorkspaceData(Data(#"{"configuration":"file:///other/project.code-workspace"}"#.utf8)))
        XCTAssertThrowsError(try context.validateWorkspaceData(Data(#"{"configuration":"file://remote/original/project.code-workspace"}"#.utf8)))
        XCTAssertThrowsError(try context.validateWorkspaceData(Data(#"{"configuration":"file:///original/../project.code-workspace"}"#.utf8)))
        let noConfig = try ArchiveVSCodeWorkspaceContext()
        try noConfig.validateWorkspaceData(nil)
        try noConfig.validateWorkspaceData(Data(#"{"folder":"","configuration":"file:///ignored"}"#.utf8))
        XCTAssertThrowsError(try noConfig.validateWorkspaceData(Data(#"{"configuration":"file:///missing"}"#.utf8)))
        XCTAssertThrowsError(try noConfig.validateWorkspaceData(Data("malformed".utf8)))
    }

    func testVSCodeConfigurationRejectsOversizedAndNonRegularFrozenData() throws {
        let bytes = Data(repeating: 65, count: ArchiveVSCodeWorkspaceContext.maximumContextBytes + 1)
        let generation = try ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(bytes.count),
            mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
        XCTAssertThrowsError(try ArchiveVSCodeWorkspaceContext(configurationLocator: "/source/project.code-workspace",
            configurationGeneration: generation, configurationData: bytes, configurationSHA256: ArchiveV2Hash.sha256(bytes)))
        for mode in [0o040700, 0o120777] {
            let invalid = try ArchiveSourceGeneration(device: 1, inode: 2, size: 0, mtimeNs: 3, ctimeNs: 4, mode: Int64(mode))
            XCTAssertThrowsError(try ArchiveVSCodeWorkspaceContext(configurationLocator: "/source/project.code-workspace",
                configurationGeneration: invalid, configurationData: Data(), configurationSHA256: ArchiveV2Hash.sha256(Data())))
        }
    }

    func testVSCodeWorkspaceLayoutRequiresClosedSameWorkspacePaths() throws {
        for absent in [["ws/workspace.json"], ["other/workspace.json"], ["ws/extra.json"]] {
            let bytes = try vscodeContextManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout["absentRelativePaths"] = absent
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
        }
    }

    private func vscodeContextManifestBytes(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(makeManifest())) as! [String: Any]
        object["schemaVersion"] = 7
        object["source"] = "vscode"
        object["locator"] = "/source/ws/chatSessions/session.jsonl"
        object.removeValue(forKey: "sessionID")
        var generation = object["generation"] as! [String: Any]
        generation["size"] = 3
        object["generation"] = generation
        var workspaceGeneration = generation
        workspaceGeneration["size"] = 2
        let config = Data(#"{"folders":[{"path":"../project"}]}"#.utf8)
        var configGeneration = generation
        configGeneration["size"] = config.count
        object["replayLayout"] = [
            "strategy": "fileSet", "relativePaths": ["ws/chatSessions/session.jsonl", "ws/workspace.json"],
            "entrypointRelativePath": "ws/chatSessions/session.jsonl", "absentRelativePaths": [] as [String],
            "files": [["relativePath": "ws/chatSessions/session.jsonl", "byteOffset": 0, "rawByteCount": 3,
                       "wholeSourceSHA256": sourceDigest, "generation": generation],
                      ["relativePath": "ws/workspace.json", "byteOffset": 3, "rawByteCount": 2,
                       "wholeSourceSHA256": sourceDigest, "generation": workspaceGeneration]],
            "vscodeWorkspaceContext": ["kind": "vscodeWorkspace", "configurationLocator": "/source/project.code-workspace",
                "configurationData": config.base64EncodedString(), "configurationSHA256": ArchiveV2Hash.sha256(config),
                "configurationGeneration": configGeneration],
        ]
        mutate(&object)
        return Data(try canonicalTestJSON(object).utf8)
    }

    func testOpenCodeSessionImageRequiresExplicitSchemaFourProvenance() throws {
        let bytes = try openCodeImageManifestBytes()
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertEqual(manifest.schemaVersion, 4)
        XCTAssertEqual(manifest.generation.size, 8192, "real source DB stat must not be replaced with image size")
        XCTAssertEqual(manifest.rawByteCount, 5, "transported image has its own byte count")
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(manifest), bytes)
    }

    func testOpenCodeImageContextCannotBeDroppedOnSchemaDowngrade() throws {
        for version in [1, 2, 3] {
            let bytes = try openCodeImageManifestBytes { object in
                object["schemaVersion"] = version
                var generation = object["generation"] as! [String: Any]
                generation["size"] = object["rawByteCount"]
                object["generation"] = generation
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), "schema \(version)")
        }
    }

    func testOpenCodeImageRequiresMatchingNativeLocatorSourceAndUnboundManifest() throws {
        for (key, value) in [("source", "codex"), ("locator", "/source/opencode.db::other"), ("sessionID", "bound-session")] {
            let bytes = try openCodeImageManifestBytes { $0[key] = value }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
        let missing = try openCodeImageManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            layout.removeValue(forKey: "sqliteSession")
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: missing))
    }

    func testOpenCodeImageRejectsInvalidScopeAndPayloadProvenance() throws {
        for (key, value) in [("kind", "nativeFile" as Any), ("databaseLocator", "../opencode.db"),
                            ("nativeSessionID", ""), ("nativeSessionID", "id\0tail"),
                            ("nativeSessionID", "other::id"), ("nativePayloadByteCount", -1),
                            ("nativePayloadByteCount", 6)] {
            let bytes = try openCodeImageManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                var context = layout["sqliteSession"] as! [String: Any]
                context[key] = value
                layout["sqliteSession"] = context
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
    }

    private func openCodeImageManifestBytes(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(makeManifest())) as! [String: Any]
        object["schemaVersion"] = 4
        object["source"] = "opencode"
        object["locator"] = "/source/opencode.db::ses-one"
        object.removeValue(forKey: "sessionID")
        var generation = object["generation"] as! [String: Any]
        generation["size"] = 8192
        object["generation"] = generation
        object["replayLayout"] = ["strategy": "singleFile", "relativePaths": ["session.sqlite"],
            "sqliteSession": ["kind": "opencodeSessionImage", "databaseLocator": "/source/opencode.db",
                "nativeSessionID": "ses-one", "nativePayloadByteCount": 2, "walGeneration": generation]]
        mutate(&object)
        return Data(try canonicalTestJSON(object).utf8)
    }

    func testKimiRegistryProjectionRequiresSchemaFiveAndRoundTripsWithoutSharedRegistryBytes() throws {
        let bytes = try kimiContextManifestBytes()
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertEqual(manifest.schemaVersion, 5)
        XCTAssertEqual(manifest.source, "kimi")
        XCTAssertEqual(manifest.rawByteCount, 5)
        XCTAssertEqual(manifest.replayLayout.relativePaths, ["workspace/native-session/context.jsonl"])
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(manifest), bytes)
    }

    func testKimiContextCannotBeDroppedOrReinterpretedAsAnOlderSchema() throws {
        for version in [1, 2, 3, 4] {
            let bytes = try kimiContextManifestBytes { $0["schemaVersion"] = version }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
        }
        for (key, value) in [("source", "gemini-cli"), ("source", "copilot"), ("sessionID", "already-bound"),
                             ("locator", "/native/sessions/workspace/another/context.jsonl"),
                             ("locator", "relative/workspace/native-session/context.jsonl"),
                             ("locator", "/native/../sessions/workspace/native-session/context.jsonl")] {
            let bytes = try kimiContextManifestBytes { $0[key] = value }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
        let absent = try kimiContextManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            layout.removeValue(forKey: "kimiProjectContext")
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: absent))
    }

    func testKimiProvenanceRejectsForeignIdentityInvalidRegistryAndUnsafeDirectory() throws {
        let values: [(String, Any)] = [("kind", "genericRegistry"), ("workspaceName", "other"),
            ("workspaceName", "../workspace"), ("nativeSessionID", "another"), ("nativeSessionID", ""),
            ("nativeSessionID", "id\0tail"), ("cwd", "relative"), ("cwd", "/bad\0root"),
            ("registryLocator", "relative.json"), ("registryLocator", "/native/../kimi.json"),
            ("registrySHA256", "invalid")]
        for (key, value) in values {
            let bytes = try kimiContextManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                var context = layout["kimiProjectContext"] as! [String: Any]
                context[key] = value
                layout["kimiProjectContext"] = context
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
    }

    func testKimiClosedDependencySetRejectsMissingWireSlotAndForeignAbsences() throws {
        for absent in [[], ["workspace/another/wire.jsonl"], ["workspace/native-session/kimi.json"],
                       ["workspace/native-session/wire.jsonl", "workspace/native-session/context_1.jsonl"]] {
            let bytes = try kimiContextManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout["absentRelativePaths"] = absent
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
        }
    }

    func testKimiRejectsMixedGeminiAndSQLiteContexts() throws {
        let gemini = try JSONSerialization.jsonObject(with: geminiContextManifestBytes()) as! [String: Any]
        let geminiLayout = gemini["replayLayout"] as! [String: Any]
        let sqlite = try JSONSerialization.jsonObject(with: openCodeImageManifestBytes()) as! [String: Any]
        let sqliteLayout = sqlite["replayLayout"] as! [String: Any]
        for (key, value) in [("geminiProjectContext", geminiLayout["geminiProjectContext"]!),
                             ("sqliteSession", sqliteLayout["sqliteSession"]!)] {
            let bytes = try kimiContextManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout[key] = value
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
        }
    }

    func testKimiClosedSetAllowsNativeShardsAndPresentWireButRejectsSiblingFilesAndDuplicateOrder() throws {
        let valid = try kimiContextManifestBytes { object in
            self.addKimiMembers(["workspace/native-session/context_-1.jsonl", "workspace/native-session/context_sub_2.jsonl", "workspace/native-session/wire.jsonl"], to: &object)
        }
        XCTAssertNoThrow(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: valid))
        let mixedFamily = try kimiContextManifestBytes { object in
            self.addKimiMembers(["workspace/native-session/context_1.jsonl", "workspace/native-session/context_sub_1.jsonl"], to: &object)
        }
        XCTAssertNoThrow(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: mixedFamily),
            "distinct families at the same numeric index are a closed native set")
        for extra in [["workspace/native-session/private.json"], ["workspace/other/context_1.jsonl"],
                      ["workspace/native-session/context_1.jsonl", "workspace/native-session/context_01.jsonl"],
                      ["workspace/native-session/context_sub_1.jsonl", "workspace/native-session/context_sub_01.jsonl"]] {
            let invalid = try kimiContextManifestBytes { object in self.addKimiMembers(extra, to: &object) }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: invalid))
        }
    }

    private func addKimiMembers(_ names: [String], to object: inout [String: Any]) {
        var layout = object["replayLayout"] as! [String: Any]
        var files = layout["files"] as! [[String: Any]]
        var generation = object["generation"] as! [String: Any]
        generation["size"] = 0
        for name in names {
            files.append(["relativePath": name, "byteOffset": 5, "rawByteCount": 0,
                          "wholeSourceSHA256": ArchiveV2Hash.sha256(Data()), "generation": generation])
        }
        files.sort { ($0["relativePath"] as! String).utf8.lexicographicallyPrecedes(($1["relativePath"] as! String).utf8) }
        layout["files"] = files
        layout["relativePaths"] = files.map { $0["relativePath"] as! String }
        if names.contains("workspace/native-session/wire.jsonl") { layout["absentRelativePaths"] = [String]() }
        object["replayLayout"] = layout
    }

    private func kimiContextManifestBytes(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(makeManifest())) as! [String: Any]
        object["schemaVersion"] = 5
        object["source"] = "kimi"
        object["locator"] = "/native/sessions/workspace/native-session/context.jsonl"
        object.removeValue(forKey: "sessionID")
        let generation = object["generation"] as! [String: Any]
        let primary = "workspace/native-session/context.jsonl"
        object["replayLayout"] = ["strategy": "fileSet", "relativePaths": [primary],
            "entrypointRelativePath": primary,
            "files": [["relativePath": primary, "byteOffset": 0, "rawByteCount": 5,
                "wholeSourceSHA256": sourceDigest, "generation": generation]],
            "absentRelativePaths": ["workspace/native-session/wire.jsonl"],
            "kimiProjectContext": ["kind": "kimiWorkDirsRegistryProjection", "workspaceName": "workspace",
                "nativeSessionID": "native-session", "cwd": "/repo/kimi", "registryLocator": "/native/kimi.json",
                "registryGeneration": generation, "registrySHA256": manifestDigest]]
        mutate(&object)
        return Data(try canonicalTestJSON(object).utf8)
    }

    func testGeminiRegistryProjectionRequiresSchemaThreeAndRoundTripsWithoutRegistryBytes() throws {
        let bytes = try geminiContextManifestBytes()
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(manifest.source, "gemini-cli")
        XCTAssertEqual(manifest.rawByteCount, 5, "registry evidence is metadata, not a transported file")
        XCTAssertEqual(manifest.replayLayout.relativePaths, ["project/chats/stem.json"])
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(manifest), bytes)
    }

    func testGeminiContextCannotBeSilentlyDroppedByOldSchemaOrWrongSource() throws {
        for version in [1, 2] {
            let bytes = try geminiContextManifestBytes { object in
                object["schemaVersion"] = version
                if version == 1 {
                    var layout = object["replayLayout"] as! [String: Any]
                    layout["strategy"] = "singleFile"
                    layout.removeValue(forKey: "entrypointRelativePath")
                    layout.removeValue(forKey: "files")
                    layout.removeValue(forKey: "absentRelativePaths")
                    object["replayLayout"] = layout
                }
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), "schema \(version) cannot discard cwd provenance")
        }
        for source in ["copilot", "codex"] {
            let bytes = try geminiContextManifestBytes { $0["source"] = source }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
        }
        let missing = try geminiContextManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            layout.removeValue(forKey: "geminiProjectContext")
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: missing))
    }

    func testGeminiRegistryProjectionRejectsInvalidProvenanceAndForeignProject() throws {
        let values: [(String, Any)] = [("kind", "nativeFile"), ("projectName", "../project"),
            ("projectName", "other-project"), ("cwd", "relative"), ("cwd", "/bad\0root"),
            ("registryLocator", "relative.json"), ("registrySHA256", "bad-hash")]
        for (key, value) in values {
            let bytes = try geminiContextManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                var context = layout["geminiProjectContext"] as! [String: Any]
                context[key] = value
                layout["geminiProjectContext"] = context
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), key)
        }
    }

    private func geminiContextManifestBytes(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(makeManifest())) as! [String: Any]
        object["schemaVersion"] = 3
        object["source"] = "gemini-cli"
        object["locator"] = "/native/tmp/project/chats/stem.json"
        object.removeValue(forKey: "sessionID")
        let generation = object["generation"] as! [String: Any]
        object["replayLayout"] = ["strategy": "fileSet", "relativePaths": ["project/chats/stem.json"],
            "entrypointRelativePath": "project/chats/stem.json",
            "files": [["relativePath": "project/chats/stem.json", "byteOffset": 0,
                "rawByteCount": 5, "wholeSourceSHA256": sourceDigest, "generation": generation]],
            "absentRelativePaths": ["project/.project_root", "project/chats/native-session.engram.json"],
            "geminiProjectContext": ["kind": "geminiProjectsRegistryProjection", "projectName": "project", "cwd": "/repo/gemini",
                "registryLocator": "/native/projects.json", "registryGeneration": generation, "registrySHA256": manifestDigest]]
        mutate(&object)
        return Data(try canonicalTestJSON(object).utf8)
    }

    func testFileSetManifestPreservesPrimaryGenerationAndExplicitAuxiliaryBoundaries() throws {
        let bytes = try fileSetManifestBytes()
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.generation.size, 5, "top-level generation remains the real primary file stat")
        XCTAssertEqual(manifest.rawByteCount, 8, "transport budget covers all captured files")
        XCTAssertEqual(manifest.replayLayout.strategy.rawValue, "fileSet")
        XCTAssertEqual(manifest.replayLayout.relativePaths, ["session/events.jsonl", "session/workspace.yaml"])
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(manifest), bytes)
    }

    func testFileSetManifestRepresentsEmptyFilesAndDeclaredAbsentDependencies() throws {
        let bytes = try fileSetManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            var files = layout["files"] as! [[String: Any]]
            var empty = files[1]
            empty["relativePath"] = "session/z-empty.txt"
            empty["byteOffset"] = 8
            empty["rawByteCount"] = 0
            empty["wholeSourceSHA256"] = ArchiveV2Hash.sha256(Data())
            var generation = empty["generation"] as! [String: Any]
            generation["size"] = 0
            empty["generation"] = generation
            files.append(empty)
            layout["files"] = files
            layout["relativePaths"] = files.map { $0["relativePath"] as! String }
            object["replayLayout"] = layout
        }
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertEqual(manifest.rawByteCount, 8)
        XCTAssertEqual(manifest.replayLayout.relativePaths.count, 3)
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(manifest), bytes)
    }

    func testFileSetManifestRejectsAmbiguousOrIncompleteByteAndPathMaps() throws {
        let mutations: [([String: Any]) -> [String: Any]] = [
            { var f = $0; f["byteOffset"] = 4; return f },
            { var f = $0; f["byteOffset"] = 6; return f },
            { var f = $0; f["rawByteCount"] = 4; return f },
            { var f = $0; f["wholeSourceSHA256"] = "invalid"; return f },
            { var f = $0; var g = f["generation"] as! [String: Any]; g["mode"] = 16832; f["generation"] = g; return f },
            { var f = $0; f["relativePath"] = "../outside"; return f },
            { var f = $0; f["relativePath"] = "session/events.jsonl"; return f },
            { var f = $0; f["relativePath"] = "session/EVENTS.JSONL"; return f },
            { var f = $0; f["relativePath"] = "session/events.jsonl/child"; return f },
        ]
        for mutate in mutations {
            let bytes = try fileSetManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                var files = layout["files"] as! [[String: Any]]
                files[1] = mutate(files[1])
                layout["files"] = files
                layout["relativePaths"] = files.map { $0["relativePath"] as! String }
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
        }
        for field in ["entrypointRelativePath", "files", "absentRelativePaths"] {
            let bytes = try fileSetManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout.removeValue(forKey: field)
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), field)
        }
    }

    func testFileSetManifestRejectsLegacySchemaBindingAndAbsentPresentAliases() throws {
        for mutate: (inout [String: Any]) -> Void in [
            { $0["schemaVersion"] = 1 },
            { $0["sessionID"] = "bound-session" },
            { object in
                var generation = object["generation"] as! [String: Any]
                generation["inode"] = 999
                object["generation"] = generation
            },
            { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout["entrypointRelativePath"] = "session/missing.jsonl"
                object["replayLayout"] = layout
            },
            { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout["absentRelativePaths"] = ["session/EVENTS.JSONL"]
                object["replayLayout"] = layout
            },
        ] {
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self,
                from: fileSetManifestBytes(mutate)))
        }
    }

    func testFileSetPreservesByteDistinctUnicodeSpellingWithoutAllowingAliases() throws {
        let decomposed = "session/z-cafe\u{0301}.yaml"
        let bytes = try fileSetManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            var files = layout["files"] as! [[String: Any]]
            files[1]["relativePath"] = decomposed
            layout["files"] = files
            layout["relativePaths"] = files.map { $0["relativePath"] as! String }
            object["replayLayout"] = layout
        }
        let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
        XCTAssertEqual(Array(manifest.replayLayout.relativePaths[1].utf8), Array(decomposed.utf8))
        XCTAssertEqual(try ArchiveCanonicalJSON.encode(manifest), bytes)
        let aliased = try fileSetManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            var files = layout["files"] as! [[String: Any]]
            files[1]["relativePath"] = decomposed
            layout["files"] = files
            layout["relativePaths"] = files.map { $0["relativePath"] as! String }
            layout["absentRelativePaths"] = ["session/z-café.yaml"]
            object["replayLayout"] = layout
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: aliased))
    }

    func testFileSetDependencyBoundsRejectExcessiveFanoutAndDeepPaths() throws {
        let atLimit = try fileSetManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            layout["absentRelativePaths"] = (0..<62).map { String(format: "optional-%03d", $0) }
            object["replayLayout"] = layout
        }
        XCTAssertNoThrow(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: atLimit))
        for paths in [(0..<63).map { String(format: "optional-%03d", $0) },
                      [String(repeating: "a/", count: 32) + "file"], [String(repeating: "a", count: 4097)]] {
            let bytes = try fileSetManifestBytes { object in
                var layout = object["replayLayout"] as! [String: Any]
                layout["absentRelativePaths"] = paths
                object["replayLayout"] = layout
            }
            XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
        }
    }

    func testFileSetRejectsNonCanonicalMemberOrderEvenWithConsistentOffsets() throws {
        let bytes = try fileSetManifestBytes { object in
            var layout = object["replayLayout"] as! [String: Any]
            let files = layout["files"] as! [[String: Any]]
            var first = files[1]
            first["byteOffset"] = 0
            var second = files[0]
            second["byteOffset"] = 3
            layout["files"] = [first, second]
            layout["relativePaths"] = [first["relativePath"]!, second["relativePath"]!]
            object["replayLayout"] = layout
            let digest = ArchiveV2Hash.sha256(Data("cwdhello".utf8))
            object["wholeSourceSHA256"] = digest
            object["chunks"] = [["ordinal": 0, "rawSHA256": digest, "rawByteCount": 8]]
        }
        XCTAssertThrowsError(try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes))
    }

    func testCursorModernFileSetAcceptsClosedStoreTranscriptAndPairedLayouts() throws {
        let layouts: [(String, CursorModernLayout)] = [
            ("store-only", .store(wal: false, meta: false)),
            ("store+wal", .store(wal: true, meta: false)),
            ("store+meta", .store(wal: false, meta: true)),
            ("store+wal+meta", .store(wal: true, meta: true)),
            ("transcript-only", .transcript),
            ("paired", .paired(wal: false, meta: false)),
            ("paired+wal+meta", .paired(wal: true, meta: true)),
        ]
        for (name, layout) in layouts {
            let manifest = try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self, from: cursorModernManifestBytes(layout))
            XCTAssertTrue(ArchiveSourceDescriptor.isCursorModernFileSet(manifest), name)
            XCTAssertEqual(manifest.schemaVersion, 2, name)
            XCTAssertEqual(manifest.source, "cursor", name)
            XCTAssertNil(manifest.sessionID, name)
            XCTAssertNil(manifest.replayLayout.geminiProjectContext, name)
            XCTAssertNil(manifest.replayLayout.kimiProjectContext, name)
            XCTAssertNil(manifest.replayLayout.sqliteSession, name)
        }
    }

    func testCursorModernFileSetRejectsOpenMembershipAndWrongIdentity() throws {
        XCTAssertFalse(ArchiveSourceDescriptor.isCursorModernFileSet(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: fileSetManifestBytes())))
        XCTAssertFalse(ArchiveSourceDescriptor.isCursorModernFileSet(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: geminiContextManifestBytes())))
        XCTAssertFalse(ArchiveSourceDescriptor.isCursorModernFileSet(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: kimiContextManifestBytes())))
        XCTAssertFalse(ArchiveSourceDescriptor.isCursorModernFileSet(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: openCodeImageManifestBytes())))
        XCTAssertFalse(ArchiveSourceDescriptor.isCursorModernFileSet(try makeManifest()), "bound-session schema 1")

        let store = "chats/ws/sid/store.db"
        let transcript = "projects/proj/agent-transcripts/sid/sid.jsonl"
        let cases: [(String, Data)] = [
            ("wrong-source", try cursorModernManifestBytes(.store(wal: false, meta: false), source: "copilot")),
            ("wrong-schema-copilot-shape", try fileSetManifestBytes { $0["source"] = "cursor" }),
            ("noncanonical-locator", try cursorModernManifestBytes(.store(wal: false, meta: false),
                locator: "/native/.cursor/./chats/ws/sid/store.db")),
            ("escaped-locator", try cursorModernManifestBytes(.store(wal: false, meta: false),
                locator: "/native/../.cursor/chats/ws/sid/store.db")),
            ("locator-not-entrypoint", try cursorModernManifestBytes(.paired(wal: false, meta: false),
                locator: "/native/.cursor/\(store)")),
            ("store-entrypoint-when-paired", try cursorModernManifestBytes(.paired(wal: false, meta: false),
                entrypoint: store, locator: "/native/.cursor/\(store)")),
            ("wal-entrypoint", try cursorModernManifestBytes(.store(wal: true, meta: false),
                entrypoint: "chats/ws/sid/store.db-wal", locator: "/native/.cursor/chats/ws/sid/store.db-wal")),
            ("notes", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraPresent: ["chats/ws/sid/notes.txt"])),
            ("shm-present", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraPresent: ["chats/ws/sid/store.db-shm"])),
            ("journal-present", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraPresent: ["chats/ws/sid/store.db-journal"])),
            ("shm-absent", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraAbsent: ["chats/ws/sid/store.db-shm"])),
            ("journal-absent", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraAbsent: ["chats/ws/sid/store.db-journal"])),
            ("invented-store-absence", try cursorModernManifestBytes(.transcript, extraAbsent: [store])),
            ("invented-transcript-absence", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraAbsent: [transcript])),
            ("mismatched-id", try cursorModernManifestBytes(.paired(wal: false, meta: false), transcriptID: "other")),
            ("wal-other-workspace", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraPresent: ["chats/other/sid/store.db-wal"], replaceAbsent: ["chats/ws/sid/meta.json"])),
            ("extra-store", try cursorModernManifestBytes(.store(wal: false, meta: false),
                extraPresent: ["chats/ws/other/store.db"])),
            ("extra-transcript", try cursorModernManifestBytes(.paired(wal: false, meta: false),
                extraPresent: ["projects/other/agent-transcripts/sid/sid.jsonl"])),
        ]
        for (name, bytes) in cases {
            let manifest = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)
            XCTAssertFalse(ArchiveSourceDescriptor.isCursorModernFileSet(manifest), name)
        }
    }

    private func fileSetManifestBytes(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let primary = Data("hello".utf8)
        let auxiliary = Data("cwd".utf8)
        var generation: [String: Any] = ["ctimeNs": 6, "device": 1, "inode": 2, "mode": 33188, "mtimeNs": 5, "size": primary.count]
        let first: [String: Any] = ["relativePath": "session/events.jsonl", "byteOffset": 0,
            "rawByteCount": primary.count, "wholeSourceSHA256": ArchiveV2Hash.sha256(primary), "generation": generation]
        generation["inode"] = 3
        generation["size"] = auxiliary.count
        let second: [String: Any] = ["relativePath": "session/workspace.yaml", "byteOffset": primary.count,
            "rawByteCount": auxiliary.count, "wholeSourceSHA256": ArchiveV2Hash.sha256(auxiliary), "generation": generation]
        let combined = primary + auxiliary
        var object: [String: Any] = [
            "schemaVersion": 2, "captureID": captureDigest, "machineID": machineID, "source": "copilot",
            "locator": "/client/copilot/session/events.jsonl", "capturedAt": "2026-09-08T00:00:00Z",
            "generation": first["generation"]!, "wholeSourceSHA256": ArchiveV2Hash.sha256(combined),
            "rawByteCount": combined.count, "chunkSize": 8 * 1024 * 1024,
            "chunks": [["ordinal": 0, "rawSHA256": ArchiveV2Hash.sha256(combined), "rawByteCount": combined.count]],
            "replayLayout": ["strategy": "fileSet", "relativePaths": ["session/events.jsonl", "session/workspace.yaml"],
                "entrypointRelativePath": "session/events.jsonl", "files": [first, second],
                "absentRelativePaths": ["session/checkpoints/index.md"]],
        ]
        mutate(&object)
        return Data(try canonicalTestJSON(object).utf8)
    }

    private enum CursorModernLayout {
        case store(wal: Bool, meta: Bool)
        case transcript
        case paired(wal: Bool, meta: Bool)
    }

    private func cursorModernManifestBytes(
        _ layout: CursorModernLayout,
        source: String = "cursor",
        workspace: String = "ws",
        id: String = "sid",
        project: String = "proj",
        transcriptID: String? = nil,
        extraPresent: [String] = [],
        extraAbsent: [String] = [],
        replaceAbsent: [String]? = nil,
        entrypoint: String? = nil,
        locator: String? = nil,
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) throws -> Data {
        let store = "chats/\(workspace)/\(id)/store.db"
        let wal = store + "-wal"
        let meta = "chats/\(workspace)/\(id)/meta.json"
        let jsonlID = transcriptID ?? id
        let transcript = "projects/\(project)/agent-transcripts/\(jsonlID)/\(jsonlID).jsonl"
        var present: [String] = []
        var absent: [String] = []
        var hasTranscript = false
        switch layout {
        case .store(let hasWAL, let hasMeta):
            present.append(store)
            if hasWAL { present.append(wal) } else { absent.append(wal) }
            if hasMeta { present.append(meta) } else { absent.append(meta) }
        case .transcript:
            hasTranscript = true
            present.append(transcript)
        case .paired(let hasWAL, let hasMeta):
            hasTranscript = true
            present.append(store)
            present.append(transcript)
            if hasWAL { present.append(wal) } else { absent.append(wal) }
            if hasMeta { present.append(meta) } else { absent.append(meta) }
        }
        present.append(contentsOf: extraPresent)
        if let replaceAbsent {
            absent = replaceAbsent
        } else {
            absent.append(contentsOf: extraAbsent)
        }
        present.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        absent.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let entry = entrypoint ?? (hasTranscript ? transcript : store)
        let primary = Data("hello".utf8)
        var files: [[String: Any]] = []
        var offset = 0
        var inode = 2
        for path in present {
            let payload = path.utf8.elementsEqual(entry.utf8) ? primary : Data()
            let generation: [String: Any] = [
                "ctimeNs": 6, "device": 1, "inode": inode, "mode": 33188, "mtimeNs": 5, "size": payload.count,
            ]
            files.append([
                "relativePath": path, "byteOffset": offset, "rawByteCount": payload.count,
                "wholeSourceSHA256": ArchiveV2Hash.sha256(payload), "generation": generation,
            ])
            offset += payload.count
            inode += 1
        }
        let combined = primary
        let entryGeneration = files.first { ($0["relativePath"] as! String).utf8.elementsEqual(entry.utf8) }?["generation"]
        var object: [String: Any] = [
            "schemaVersion": 2, "captureID": captureDigest, "machineID": machineID, "source": source,
            "locator": locator ?? "/native/.cursor/\(entry)", "capturedAt": "2026-09-08T00:00:00Z",
            "generation": entryGeneration ?? files[0]["generation"]!,
            "wholeSourceSHA256": ArchiveV2Hash.sha256(combined),
            "rawByteCount": combined.count, "chunkSize": 8 * 1024 * 1024,
            "chunks": [["ordinal": 0, "rawSHA256": ArchiveV2Hash.sha256(combined), "rawByteCount": combined.count]],
            "replayLayout": [
                "strategy": "fileSet", "relativePaths": present, "entrypointRelativePath": entry,
                "files": files, "absentRelativePaths": absent,
            ],
        ]
        mutate(&object)
        return Data(try canonicalTestJSON(object).utf8)
    }

    // JSONSerialization.sortedKeys uses localized ordering (capturedAt before
    // captureID), unlike JSONEncoder's canonical UTF-8 key ordering.
    private func canonicalTestJSON(_ value: Any) throws -> String {
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return "{" + (try keys.map { try canonicalTestJSON($0) + ":" + canonicalTestJSON(object[$0]!) }).joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return "[" + (try array.map(canonicalTestJSON)).joined(separator: ",") + "]"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }

    func testCanonicalDecodeRejectsReorderedKeys() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let canonicalString = String(decoding: canonical, as: UTF8.self)
        let withoutSchemaVersion = canonicalString.replacingOccurrences(
            of: ",\"schemaVersion\":1",
            with: ""
        )
        let reordered = Data(
            ("{\"schemaVersion\":1," + String(withoutSchemaVersion.dropFirst())).utf8
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: reordered)
        )
    }

    func testCanonicalDecodeRejectsInsignificantWhitespace() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        var withLeadingWhitespace = Data(" \n".utf8)
        withLeadingWhitespace.append(canonical)

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(
                ArchiveSourceManifest.self,
                from: withLeadingWhitespace
            )
        )
    }

    func testCanonicalDecodeRejectsUTF8BOM() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(canonical)

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: withBOM)
        )
    }

    func testCanonicalDecodeRejectsAlternateEscapedSlashBytes() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let alternate = Data(
            String(decoding: canonical, as: UTF8.self)
                .replacingOccurrences(
                    of: "/tmp/source.jsonl",
                    with: "\\/tmp\\/source.jsonl"
                )
                .utf8
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: alternate)
        )
    }

    func testCanonicalDecodeRejectsDuplicateKeys() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let canonicalString = String(decoding: canonical, as: UTF8.self)
        let duplicate = Data(
            ("{\"schemaVersion\":1," + String(canonicalString.dropFirst())).utf8
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: duplicate)
        )
    }

    func testDigestValidationRejectsUppercaseAndShortValues() {
        XCTAssertThrowsError(
            try ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: String(repeating: "A", count: 64),
                rawByteCount: 1
            )
        )
        XCTAssertThrowsError(
            try ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: String(repeating: "a", count: 63),
                rawByteCount: 1
            )
        )
    }

    func testManifestRejectsNonContiguousChunkOrdinals() throws {
        let chunk = try ArchiveChunkReference(
            ordinal: 1,
            rawSHA256: chunkDigest,
            rawByteCount: 5
        )

        XCTAssertThrowsError(try makeManifest(chunks: [chunk], rawByteCount: 5)) { error in
            XCTAssertEqual(
                error as? ArchiveV2ValidationError,
                .nonContiguousChunkOrdinal(expected: 0, actual: 1)
            )
        }
    }

    func testManifestRejectsAggregateByteMismatch() throws {
        let chunk = try ArchiveChunkReference(
            ordinal: 0,
            rawSHA256: chunkDigest,
            rawByteCount: 5
        )

        XCTAssertThrowsError(try makeManifest(chunks: [chunk], rawByteCount: 4)) { error in
            XCTAssertEqual(
                error as? ArchiveV2ValidationError,
                .aggregateRawByteCountMismatch(expected: 4, actual: 5)
            )
        }
    }

    func testManifestDecodeRevalidatesSchemaVersion() throws {
        let encoded = try ArchiveCanonicalJSON.encode(makeManifest())
        let invalid = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "\"schemaVersion\":1",
                with: "\"schemaVersion\":2"
            ).data(using: .utf8)
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: invalid)
        )
    }

    func testReplayLayoutRejectsInvalidV1Paths() throws {
        let invalidPathSets = [
            [],
            [""],
            ["."],
            ["/absolute/session.jsonl"],
            ["sessions//session.jsonl"],
            ["sessions/./session.jsonl"],
            ["sessions/../session.jsonl"],
            ["sessions/session\u{0}.jsonl"],
            ["session.jsonl", "session.jsonl"],
            ["one.jsonl", "two.jsonl"],
        ]

        for relativePaths in invalidPathSets {
            XCTAssertThrowsError(
                try ArchiveReplayLayout(
                    strategy: .singleFile,
                    relativePaths: relativePaths
                ),
                "Expected rejection for \(relativePaths)"
            )
        }
    }

    func testReplayLayoutDecodeRevalidatesRelativePath() throws {
        let encoded = try ArchiveCanonicalJSON.encode(makeManifest())
        let invalid = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?.replacingOccurrences(
                of: "sessions/session.jsonl",
                with: "/absolute/session.jsonl"
            ).data(using: .utf8)
        )

        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: invalid)
        )
    }

    func testReceiptValidatesAgainstCanonicalBoundManifest() throws {
        let manifestBytes = try ArchiveCanonicalJSON.encode(makeManifest())
        let receipt = try makeReceipt(manifestSHA256: ArchiveV2Hash.sha256(manifestBytes))

        XCTAssertNoThrow(
            try receipt.validate(againstCanonicalManifestBytes: manifestBytes)
        )
    }

    func testReceiptValidationRejectsEveryManifestRelationMismatch() throws {
        let manifestBytes = try ArchiveCanonicalJSON.encode(makeManifest())
        let manifestSHA256 = ArchiveV2Hash.sha256(manifestBytes)
        let mismatches: [(String, ArchiveServerReceipt, ArchiveV2ValidationError)] = [
            (
                "machineID",
                try makeReceipt(
                    machineID: "223e4567-e89b-12d3-a456-426614174000",
                    manifestSHA256: manifestSHA256
                ),
                .receiptManifestMismatch(field: "machineID")
            ),
            (
                "sessionID",
                try makeReceipt(
                    sessionID: "session-2",
                    manifestSHA256: manifestSHA256
                ),
                .receiptManifestMismatch(field: "sessionID")
            ),
            (
                "captureID",
                try makeReceipt(
                    captureID: String(repeating: "e", count: 64),
                    manifestSHA256: manifestSHA256
                ),
                .receiptManifestMismatch(field: "captureID")
            ),
            (
                "manifestSHA256",
                try makeReceipt(manifestSHA256: String(repeating: "e", count: 64)),
                .receiptManifestMismatch(field: "manifestSHA256")
            ),
            (
                "wholeSourceSHA256",
                try makeReceipt(
                    manifestSHA256: manifestSHA256,
                    wholeSourceSHA256: String(repeating: "e", count: 64)
                ),
                .receiptManifestMismatch(field: "wholeSourceSHA256")
            ),
            (
                "objectCount",
                try makeReceipt(manifestSHA256: manifestSHA256, objectCount: 2),
                .receiptManifestMismatch(field: "objectCount")
            ),
            (
                "rawByteCount",
                try makeReceipt(manifestSHA256: manifestSHA256, rawByteCount: 6),
                .receiptManifestMismatch(field: "rawByteCount")
            ),
        ]

        for (field, receipt, expectedError) in mismatches {
            XCTAssertThrowsError(
                try receipt.validate(againstCanonicalManifestBytes: manifestBytes),
                "Expected mismatch for \(field)"
            ) { error in
                XCTAssertEqual(error as? ArchiveV2ValidationError, expectedError)
            }
        }
    }

    func testReceiptValidationRejectsUnboundManifest() throws {
        let manifestBytes = try ArchiveCanonicalJSON.encode(
            makeManifest(sessionID: nil)
        )
        let receipt = try makeReceipt(manifestSHA256: ArchiveV2Hash.sha256(manifestBytes))

        XCTAssertThrowsError(
            try receipt.validate(againstCanonicalManifestBytes: manifestBytes)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveV2ValidationError,
                .receiptRequiresBoundManifest
            )
        }
    }

    func testReceiptValidationRejectsNonCanonicalManifestBytes() throws {
        let canonical = try ArchiveCanonicalJSON.encode(makeManifest())
        let receipt = try makeReceipt(manifestSHA256: ArchiveV2Hash.sha256(canonical))
        var nonCanonical = Data(" ".utf8)
        nonCanonical.append(canonical)

        XCTAssertThrowsError(
            try receipt.validate(againstCanonicalManifestBytes: nonCanonical)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveCanonicalJSONError,
                .nonCanonicalEncoding
            )
        }
    }

    func testReceiptRequiresBoundSessionID() throws {
        XCTAssertThrowsError(
            try ArchiveServerReceipt(
                schemaVersion: 1,
                serverID: "hq",
                machineID: machineID,
                sessionID: "",
                captureID: captureDigest,
                manifestSHA256: manifestDigest,
                wholeSourceSHA256: sourceDigest,
                objectCount: 1,
                rawByteCount: 5,
                storedAt: "2026-07-11T00:01:00.000Z"
            )
        )

        let receiptWithoutSession = Data("{\"captureID\":\"\(captureDigest)\",\"machineID\":\"\(machineID)\",\"manifestSHA256\":\"\(manifestDigest)\",\"objectCount\":1,\"rawByteCount\":5,\"schemaVersion\":1,\"serverID\":\"hq\",\"storedAt\":\"2026-07-11T00:01:00.000Z\",\"wholeSourceSHA256\":\"\(sourceDigest)\"}".utf8)
        XCTAssertThrowsError(
            try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: receiptWithoutSession)
        )

        XCTAssertThrowsError(
            try makeReceipt(schemaVersion: 2)
        )
        XCTAssertThrowsError(
            try makeReceipt(serverID: "")
        )

        let receipt = try makeReceipt()
        let encoded = try ArchiveCanonicalJSON.encode(receipt)
        XCTAssertEqual(
            try ArchiveCanonicalJSON.decode(ArchiveServerReceipt.self, from: encoded),
            receipt
        )
    }

    func testReceiptRequiresCanonicalFractionalSecondUTCTimestamp() throws {
        let nonCanonicalValues = [
            "2026-07-11T00:01:00Z",
            "2026-07-11T00:01:00.000+00:00",
            "2026-07-11T00:01:00.00Z",
            "2026-07-11T00:01:00.0000Z",
            "2026-07-11t00:01:00.000z",
            "2026-07-11T00:01:00.000Z ",
        ]

        for storedAt in nonCanonicalValues {
            XCTAssertThrowsError(
                try ArchiveServerReceipt(
                    serverID: "hq",
                    machineID: machineID,
                    sessionID: "session-1",
                    captureID: captureDigest,
                    manifestSHA256: manifestDigest,
                    wholeSourceSHA256: sourceDigest,
                    objectCount: 1,
                    rawByteCount: 5,
                    storedAt: storedAt
                ),
                "Expected non-canonical timestamp rejection for \(storedAt)"
            ) { error in
                XCTAssertEqual(
                    error as? ArchiveV2ValidationError,
                    .invalidValue(field: "storedAt")
                )
            }
        }

        XCTAssertNoThrow(
            try ArchiveServerReceipt(
                serverID: "hq",
                machineID: machineID,
                sessionID: "session-1",
                captureID: captureDigest,
                manifestSHA256: manifestDigest,
                wholeSourceSHA256: sourceDigest,
                objectCount: 1,
                rawByteCount: 5,
                storedAt: "2026-07-11T00:01:00.000Z"
            )
        )
    }

    private func makeReceipt(
        schemaVersion: Int = 1,
        serverID: String = "hq",
        machineID: String? = nil,
        sessionID: String = "session-1",
        captureID: String? = nil,
        manifestSHA256: String? = nil,
        wholeSourceSHA256: String? = nil,
        objectCount: Int = 1,
        rawByteCount: Int64 = 5
    ) throws -> ArchiveServerReceipt {
        let resolvedManifestSHA256 = try manifestSHA256 ?? ArchiveV2Hash.sha256(
            ArchiveCanonicalJSON.encode(makeManifest())
        )
        return try ArchiveServerReceipt(
            schemaVersion: schemaVersion,
            serverID: serverID,
            machineID: machineID ?? self.machineID,
            sessionID: sessionID,
            captureID: captureID ?? captureDigest,
            manifestSHA256: resolvedManifestSHA256,
            wholeSourceSHA256: wholeSourceSHA256 ?? sourceDigest,
            objectCount: objectCount,
            rawByteCount: rawByteCount,
            storedAt: "2026-07-11T00:01:00.000Z"
        )
    }

    private func makeManifest(
        chunks: [ArchiveChunkReference]? = nil,
        rawByteCount: Int64 = 5,
        sessionID: String? = "session-1"
    ) throws -> ArchiveSourceManifest {
        let generation = try ArchiveSourceGeneration(
            device: 1,
            inode: 2,
            size: rawByteCount,
            mtimeNs: 5,
            ctimeNs: 6,
            mode: 33_188
        )
        let resolvedChunks = try chunks ?? [
            ArchiveChunkReference(
                ordinal: 0,
                rawSHA256: chunkDigest,
                rawByteCount: 5
            ),
        ]
        let replayLayout = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["sessions/session.jsonl"]
        )
        return try ArchiveSourceManifest(
            schemaVersion: 1,
            captureID: captureDigest,
            machineID: machineID,
            source: "codex",
            locator: "/tmp/source.jsonl",
            sessionID: sessionID,
            capturedAt: "2026-07-11T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: sourceDigest,
            rawByteCount: rawByteCount,
            chunkSize: 8 * 1024 * 1024,
            chunks: resolvedChunks,
            replayLayout: replayLayout
        )
    }
}

import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

final class CaptureIngestSourceRegistryTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let nextEpoch = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let laterEpoch = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    private let journal = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
    private let root = "/fictional-client/private/claude"
    private var directory: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: directory.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testRepeatedMigrationCreatesEmptyRegistryWithoutGrantingAuthority() throws {
        try writer.migrate()
        try writer.migrate()
        guard try requireSchema() else { return }
        XCTAssertEqual(try count("capture_ingest_source_registry"), 0)
        XCTAssertEqual(try count("capture_ingest_epoch_history"), 0)
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
        XCTAssertEqual(try count("capture_ingest_ledger"), 0)
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertNil(try binding())
    }

    func testExplicitProvisionPersistsInitialAuthorityAndHistoryAcrossRestart() throws {
        let initial = try provision()
        XCTAssertEqual(initial.machineID, machine)
        XCTAssertEqual(initial.sourceInstanceID, instance)
        XCTAssertEqual(initial.source, .claudeCode)
        XCTAssertEqual(initial.configuredRoot, root)
        XCTAssertEqual(initial.approvedEpoch, epoch)
        XCTAssertEqual(initial.authorityGeneration, 1)
        XCTAssertEqual(try binding(), initial)
        let transitions = try history()
        XCTAssertEqual(transitions.count, 1)
        XCTAssertNil(transitions.first?.previousEpoch)
        XCTAssertEqual(transitions.first?.approvedEpoch, epoch)
        XCTAssertEqual(transitions.first?.authorityGeneration, 1)
        XCTAssertFalse(transitions.first?.approvedAt.isEmpty ?? true)
        try reopen()
        XCTAssertEqual(try binding(), initial)
        XCTAssertEqual(try history(), transitions)
    }

    func testExactProvisionRetryIsIdempotentAndDoesNotAppendHistory() throws {
        let initial = try provision()
        XCTAssertEqual(try provision(), initial)
        XCTAssertEqual(try history().count, 1)
        guard try requireSchema() else { return }
        XCTAssertEqual(try count("capture_ingest_source_registry"), 1)
    }

    func testKnownInstanceCannotChangeSourceRootOrEpochThroughProvision() throws {
        let initial = try provision()
        assertRegistryError(.sourceInstanceConflict) { try self.provision(source: .codex) }
        assertRegistryError(.sourceInstanceConflict) { try self.provision(configuredRoot: self.root + "-other") }
        assertRegistryError(.sourceInstanceConflict) { try self.provision(initialEpoch: self.nextEpoch) }
        XCTAssertEqual(try binding(), initial)
        XCTAssertEqual(try history().count, 1)
    }

    func testProvisionRequiresCanonicalUUIDs() throws {
        for invalid in ["", "host-name", machine.lowercased(), " \(machine)", "\(machine)\0"] {
            assertRegistryError(.invalidMachineID) { try self.provision(machineID: invalid) }
        }
        for invalid in ["", instance.lowercased(), "legacy-archive-v2", "\(instance)/root"] {
            assertRegistryError(.invalidSourceInstanceID) { try self.provision(instanceID: invalid) }
        }
        for invalid in ["", epoch.lowercased(), "\(epoch)\n"] {
            assertRegistryError(.invalidEpoch) { try self.provision(initialEpoch: invalid) }
        }
        XCTAssertNil(try binding())
    }

    func testProvisionRejectsWholeMachineAndNoncanonicalRootsWithoutFilesystemRepair() throws {
        for invalid in ["", "/", "relative", "~/sessions", "remote://host/sessions", "//client/root",
                        "/client//root", "/client/./root", "/client/../root", "/client/root/", "/client/roo\0t"] {
            assertRegistryError(.invalidConfiguredRoot) { try self.provision(configuredRoot: invalid) }
        }
        XCTAssertNil(try binding())
    }

    func testRootOverlapUsesComponentsWithinMachineAndPhysicalSource() throws {
        _ = try provision()
        for overlapping in [root, root + "/nested", "/fictional-client/private"] {
            assertRegistryError(.overlappingRoot) {
                try self.provision(instanceID: UUID().uuidString, configuredRoot: overlapping)
            }
        }
        _ = try provision(instanceID: UUID().uuidString, configuredRoot: root + "-other")
        _ = try provision(instanceID: UUID().uuidString, source: .codex)
        _ = try provision(machineID: nextEpoch)
        guard try requireSchema() else { return }
        XCTAssertEqual(try count("capture_ingest_source_registry"), 4)
    }

    func testUnicodeRootsStayByteDistinctAndDoNotBroadenEligibility() throws {
        let composed = "/fictional-client/é"
        let decomposed = "/fictional-client/e\u{301}"
        let first = try provision(configuredRoot: composed)
        _ = try provision(instanceID: nextEpoch, configuredRoot: decomposed)
        let good = try manifest(locator: composed + "/session.jsonl")
        XCTAssertEqual(try eligibility(good), .eligible(first))
        let different = try manifest(locator: decomposed + "/session.jsonl")
        XCTAssertEqual(try eligibility(different), .quarantined(.locatorOutsideRoot))
        XCTAssertEqual(Array(first.configuredRoot.utf8), Array(composed.utf8))
    }

    func testBindingEqualityDoesNotCollapseCanonicalUnicodeEquivalence() throws {
        let first = try provision(configuredRoot: "/fictional-client/é")
        let otherWriter = try EngramDatabaseWriter(path: directory.appendingPathComponent("other.sqlite").path)
        try otherWriter.migrate()
        let second = try otherWriter.write {
            try CaptureIngestSourceRegistry.provision(
                $0, machineID: machine, sourceInstanceID: instance, source: .claudeCode,
                parseFormat: .claudeDefault, configuredRoot: "/fictional-client/e\u{301}", initialEpoch: epoch
            )
        }
        XCTAssertNotEqual(first, second)
    }

    func testEligibilityRequiresExplicitProvisionAndMatchingEpochWithoutWritingAuthority() throws {
        let capture = try manifest()
        XCTAssertEqual(try eligibility(capture), .quarantined(.unknownSourceInstance))
        let initial = try provision()
        XCTAssertEqual(try eligibility(capture), .eligible(initial))
        XCTAssertEqual(try eligibility(capture, collectorEpoch: nextEpoch), .quarantined(.epochNotApproved))
        XCTAssertEqual(try eligibility(capture, instanceID: nextEpoch), .quarantined(.unknownSourceInstance))
        XCTAssertEqual(try binding(), initial)
        XCTAssertEqual(try history().count, 1)
        XCTAssertEqual(try count("capture_ingest_ledger"), 0)
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("session_index_jobs"), 0)
    }

    func testEligibilityBindsOriginalManifestDigestAndMachine() throws {
        _ = try provision()
        let capture = try manifest()
        let wrongDigest = try publication(capture, digest: String(repeating: "b", count: 64))
        XCTAssertEqual(try writer.read {
            try CaptureIngestSourceRegistry.eligibility($0, publication: wrongDigest, verifiedManifest: capture)
        }, .quarantined(.manifestMismatch))
        let wrongMachine = try manifest(machineID: nextEpoch)
        XCTAssertEqual(try eligibility(wrongMachine), .quarantined(.manifestMismatch))
    }

    func testLegacyManifestMachineUUIDNormalizationDoesNotRewriteDigestInput() throws {
        let initial = try provision()
        let legacy = try manifest(machineID: machine.lowercased())
        let canonical = try manifest()
        XCTAssertNotEqual(try ArchiveCanonicalJSON.encode(legacy), try ArchiveCanonicalJSON.encode(canonical))
        XCTAssertEqual(try eligibility(legacy), .eligible(initial))
        let wrongDigest = try publication(legacy, digest: ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(canonical)))
        XCTAssertEqual(try writer.read {
            try CaptureIngestSourceRegistry.eligibility($0, publication: wrongDigest, verifiedManifest: legacy)
        }, .quarantined(.manifestMismatch))
    }

    func testBoundOrUnsupportedCaptureAndSourceMismatchStayQuarantined() throws {
        _ = try provision()
        XCTAssertEqual(try eligibility(manifest(sessionID: "existing-session")), .quarantined(.unsupportedCaptureShape))
        XCTAssertEqual(try eligibility(manifest(source: "gemini-cli")), .quarantined(.unsupportedCaptureShape))
        XCTAssertEqual(try eligibility(manifest(source: "not-a-physical-adapter")), .quarantined(.unsupportedCaptureShape))
        XCTAssertEqual(try eligibility(manifest(source: "codex")), .quarantined(.sourceMismatch))
    }

    func testCodexPhysicalSourceCanBeProvisionedAndMatched() throws {
        let initial = try provision(source: .codex)
        XCTAssertEqual(try eligibility(manifest(source: "codex")), .eligible(initial))
    }

    func testEligibilityRejectsNoncanonicalLogicalLocators() throws {
        _ = try provision()
        for invalid in ["relative.jsonl", root + "/../session.jsonl", root + "//session.jsonl",
                        root + "/./session.jsonl", root + "/session.jsonl/", root + "/session\0.jsonl"] {
            XCTAssertEqual(try eligibility(manifest(locator: invalid)), .quarantined(.invalidLocator))
        }
    }

    func testLocatorContainmentIsStrictAndDoesNotDecodePercentEscapes() throws {
        _ = try provision()
        for outside in [root, root + "-other/session.jsonl", "/other/session.jsonl", "/fictional-client/private"] {
            XCTAssertEqual(try eligibility(manifest(locator: outside)), .quarantined(.locatorOutsideRoot))
        }
        let escapedRoot = try provision(instanceID: nextEpoch, configuredRoot: root + "%2Fnested")
        let escaped = try manifest(locator: root + "%2Fnested/session.jsonl")
        XCTAssertEqual(try eligibility(escaped, instanceID: nextEpoch), .eligible(escapedRoot))
        XCTAssertEqual(try eligibility(escaped), .quarantined(.locatorOutsideRoot))
    }

    func testDryRunIsReadOnlyAndDistinguishesPublicationsFromParserRevisionTasks() throws {
        let initial = try provision()
        let capture = try manifest()
        let currentPublication = try publication(capture)
        try seed(currentPublication, ordinal: 1, parser: "parser-1")
        try seed(currentPublication, ordinal: 1, parser: "parser-2")
        let cursor = try writer.read { try CaptureIngestLedger.checkpoint($0, serverID: "hq") }
        let candidate = try publication(capture, collectorEpoch: nextEpoch)
        try seed(candidate, ordinal: 2, requested: cursor)
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = 'parsed' WHERE parser_revision = 'parser-2'") }
        let result = try writer.read { db in
            let before = try Int64.fetchOne(db, sql: "SELECT total_changes()")
            let result = try CaptureIngestSourceRegistry.dryRunEpoch(
                db, machineID: machine, sourceInstanceID: instance, candidateEpoch: nextEpoch
            )
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT total_changes()"), before)
            return result
        }
        XCTAssertEqual(result.current, initial)
        XCTAssertEqual(result.candidateEpoch, nextEpoch)
        XCTAssertFalse(result.candidateWasPreviouslyApproved)
        XCTAssertEqual(result.currentBacklog.publicationCount, 1)
        XCTAssertEqual(result.currentBacklog.ledgerTaskCounts["pending"], 1)
        XCTAssertEqual(result.currentBacklog.ledgerTaskCounts["parsed"], 1)
        XCTAssertEqual(result.currentBacklog.ledgerTaskCounts["index_ready"], 0)
        XCTAssertEqual(result.candidateBacklog.publicationCount, 1)
        XCTAssertEqual(result.candidateBacklog.ledgerTaskCounts["pending"], 1)
        XCTAssertEqual(try binding(), initial)
        XCTAssertEqual(try history().count, 1)
        XCTAssertEqual(try count("sessions"), 0)
    }

    func testDryRunRejectsUnknownInstanceAndInvalidCandidate() throws {
        assertRegistryError(.unregisteredSourceInstance) { try self.dryRun(self.nextEpoch) }
        _ = try provision()
        assertRegistryError(.invalidEpoch) { try self.dryRun("unapproved-label") }
        let current = try dryRun(epoch)
        XCTAssertTrue(current.candidateWasPreviouslyApproved)
    }

    func testEpochApprovalUsesExpectedBindingAndPersistsMonotonicHistoryWithoutResettingLedger() throws {
        let initial = try provision()
        let capture = try manifest()
        let good = try publication(capture)
        try seed(good, ordinal: 1)
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = 'index_ready'") }
        let next = try approve(nextEpoch, expected: initial)
        XCTAssertEqual(next.approvedEpoch, nextEpoch)
        XCTAssertEqual(next.authorityGeneration, 2)
        XCTAssertEqual(next.configuredRoot, initial.configuredRoot)
        XCTAssertEqual(try binding(), next)
        let transitions = try history()
        XCTAssertEqual(transitions.count, 2)
        XCTAssertEqual(transitions.last?.previousEpoch, epoch)
        XCTAssertEqual(transitions.last?.approvedEpoch, nextEpoch)
        XCTAssertEqual(transitions.last?.authorityGeneration, 2)
        XCTAssertEqual(try eligibility(capture), .quarantined(.epochNotApproved))
        XCTAssertEqual(try eligibility(capture, collectorEpoch: nextEpoch), .eligible(next))
        XCTAssertEqual(try writer.read {
            try CaptureIngestLedger.entry($0, publicationSHA256: good.sha256(), parserRevision: "parser-1")?.status
        }, .indexReady)
        XCTAssertEqual(try writer.read { try CaptureIngestLedger.publication($0, sha256: good.sha256()) }, good)
        try reopen()
        XCTAssertEqual(try binding(), next)
        XCTAssertEqual(try history(), transitions)
    }

    func testStaleEpochOrCounterCannotApproveOrCreateAnUnknownInstance() throws {
        assertRegistryError(.unregisteredSourceInstance) {
            try self.approve(self.nextEpoch, expectedEpoch: self.epoch, generation: 1)
        }
        let initial = try provision()
        assertRegistryError(.staleBinding) { try self.approve(self.nextEpoch, expectedEpoch: self.nextEpoch, generation: 1) }
        for generation: Int64 in [0, 2, -1] {
            assertRegistryError(.staleBinding) { try self.approve(self.nextEpoch, expectedEpoch: self.epoch, generation: generation) }
        }
        XCTAssertEqual(try binding(), initial)
        XCTAssertEqual(try history().count, 1)
    }

    func testCurrentOrRetiredEpochCannotBeReapprovedAndStaleABARequestFails() throws {
        let initial = try provision()
        assertRegistryError(.epochPreviouslyApproved) { try self.approve(self.epoch, expected: initial) }
        let next = try approve(nextEpoch, expected: initial)
        assertRegistryError(.epochPreviouslyApproved) { try self.approve(self.epoch, expected: next) }
        assertRegistryError(.epochPreviouslyApproved) { try self.approve(self.nextEpoch, expected: next) }
        assertRegistryError(.staleBinding) { try self.approve(self.laterEpoch, expected: initial) }
        XCTAssertEqual(try binding(), next)
        XCTAssertEqual(try history().count, 2)
        XCTAssertTrue(try dryRun(epoch).candidateWasPreviouslyApproved)
    }

    func testAuthorityGenerationOverflowFailsWithoutUpdatingHistory() throws {
        _ = try provision()
        guard try requireSchema() else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_source_registry SET authority_generation = ?", arguments: [Int64.max])
            try db.execute(sql: "UPDATE capture_ingest_epoch_history SET authority_generation = ?", arguments: [Int64.max])
        }
        assertRegistryError(.authorityGenerationOverflow) {
            try self.approve(self.nextEpoch, expectedEpoch: self.epoch, generation: Int64.max)
        }
        XCTAssertEqual(try binding()?.authorityGeneration, Int64.max)
        XCTAssertEqual(try binding()?.approvedEpoch, epoch)
        XCTAssertEqual(try history().count, 1)
    }

    func testProvisionHistoryFailureRollsBackEvenWhenOuterWriterCatches() throws {
        guard try requireSchema() else { return }
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER injected_epoch_history_failure BEFORE INSERT ON capture_ingest_epoch_history
                BEGIN SELECT RAISE(ABORT, 'injected epoch history failure'); END
                """)
            XCTAssertThrowsError(try CaptureIngestSourceRegistry.provision(
                db, machineID: machine, sourceInstanceID: instance, source: .claudeCode,
                parseFormat: .claudeDefault, configuredRoot: root, initialEpoch: epoch
            ))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_source_registry"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_epoch_history"), 0)
            try db.execute(sql: "DROP TRIGGER injected_epoch_history_failure")
        }
        XCTAssertNil(try binding())
        _ = try provision()
        XCTAssertEqual(try history().count, 1)
    }

    func testApprovalHistoryFailureRollsBackAuthorityEvenWhenOuterWriterCatches() throws {
        let initial = try provision()
        guard try requireSchema() else { return }
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER injected_epoch_history_failure BEFORE INSERT ON capture_ingest_epoch_history
                BEGIN SELECT RAISE(ABORT, 'injected epoch history failure'); END
                """)
            XCTAssertThrowsError(try CaptureIngestSourceRegistry.approveEpoch(
                db, machineID: machine, sourceInstanceID: instance, candidateEpoch: nextEpoch,
                expectedEpoch: epoch, expectedAuthorityGeneration: 1
            ))
            XCTAssertEqual(try CaptureIngestSourceRegistry.binding(db, machineID: machine, sourceInstanceID: instance), initial)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_epoch_history"), 1)
            try db.execute(sql: "DROP TRIGGER injected_epoch_history_failure")
        }
        XCTAssertEqual(try binding(), initial)
        XCTAssertEqual(try approve(nextEpoch, expected: initial).authorityGeneration, 2)
    }

    func testAmbiguousStoredRootMappingIsQuarantinedInsteadOfChoosingOneInstance() throws {
        _ = try provision()
        guard try requireSchema() else { return }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO capture_ingest_source_registry(
                    machine_id, source_instance_id, source, parse_format, configured_root, approved_epoch, authority_generation
                ) VALUES (?, ?, ?, ?, ?, ?, 1)
                """, arguments: [machine, nextEpoch, "claude-code", "claudeDefault", root + "/nested", epoch])
            try db.execute(sql: """
                INSERT INTO capture_ingest_epoch_history(
                    machine_id, source_instance_id, previous_epoch, approved_epoch, authority_generation
                ) VALUES (?, ?, NULL, ?, 1)
                """, arguments: [machine, nextEpoch, epoch])
        }
        XCTAssertEqual(try eligibility(manifest(locator: root + "/nested/session.jsonl")), .quarantined(.ambiguousSourceMapping))
    }

    func testExplicitParseFormatsPersistAcrossRestartAndExactRetry() throws {
        let cases: [(SourceName, CaptureIngestParseFormat)] = [
            (.claudeCode, .claudeDefault), (.claudeCode, .claudeCustomProfile), (.codex, .codex),
        ]
        var expected: [CaptureIngestSourceBinding] = []
        for (source, format) in cases {
            let instanceID = UUID().uuidString
            let configuredRoot = root + "/" + format.rawValue
            let current = try provision(
                instanceID: instanceID, source: source, parseFormat: format, configuredRoot: configuredRoot
            )
            XCTAssertEqual(current.parseFormat, format)
            XCTAssertEqual(try provision(
                instanceID: instanceID, source: source, parseFormat: format, configuredRoot: configuredRoot
            ), current)
            XCTAssertEqual(try writer.read {
                try CaptureIngestSourceRegistry.history($0, machineID: machine, sourceInstanceID: instanceID).count
            }, 1)
            XCTAssertEqual(try storedFormat(instanceID: instanceID), format.rawValue)
            expected.append(current)
        }
        try reopen()
        for current in expected {
            XCTAssertEqual(try writer.read {
                try CaptureIngestSourceRegistry.binding($0, machineID: machine, sourceInstanceID: current.sourceInstanceID)
            }, current)
            XCTAssertEqual(try storedFormat(instanceID: current.sourceInstanceID), current.parseFormat.rawValue)
        }
    }

    func testParseFormatMustMatchThePhysicalSource() throws {
        let invalid: [(SourceName, CaptureIngestParseFormat)] = [
            (.claudeCode, .codex), (.codex, .claudeDefault), (.codex, .claudeCustomProfile),
            (.geminiCli, .claudeDefault), (.geminiCli, .codex),
            (.minimax, .claudeDefault), (.lobsterai, .claudeCustomProfile),
        ]
        for (index, pair) in invalid.enumerated() {
            assertRegistryError(.invalidSourceParseFormat) {
                try self.provision(
                    instanceID: UUID().uuidString, source: pair.0, parseFormat: pair.1,
                    configuredRoot: self.root + "/invalid-format-\(index)"
                )
            }
        }
        XCTAssertEqual(try count("capture_ingest_source_registry"), 0)
        XCTAssertEqual(try count("capture_ingest_epoch_history"), 0)
    }

    func testKnownInstanceCannotChangeItsExplicitParseFormat() throws {
        let initial = try provision(parseFormat: .claudeDefault)
        assertRegistryError(.sourceInstanceConflict) {
            try self.provision(parseFormat: .claudeCustomProfile)
        }
        XCTAssertEqual(try binding(), initial)
        XCTAssertEqual(try storedFormat(), CaptureIngestParseFormat.claudeDefault.rawValue)
        XCTAssertEqual(try history().count, 1)
    }

    func testParseFormatParticipatesInBindingEquality() throws {
        let initial = try provision(parseFormat: .claudeDefault)
        let other = try EngramDatabaseWriter(path: directory.appendingPathComponent("other-format.sqlite").path)
        try other.migrate()
        let custom = try other.write {
            try CaptureIngestSourceRegistry.provision(
                $0, machineID: machine, sourceInstanceID: instance, source: .claudeCode,
                parseFormat: .claudeCustomProfile, configuredRoot: root, initialEpoch: epoch
            )
        }
        XCTAssertNotEqual(initial, custom)
        XCTAssertEqual(custom.parseFormat, .claudeCustomProfile)
    }

    func testEpochApprovalAndDryRunPreserveTheProvisionedFormatAndHistory() throws {
        let initial = try provision(parseFormat: .claudeCustomProfile)
        let next = try approve(nextEpoch, expected: initial)
        XCTAssertEqual(next.parseFormat, .claudeCustomProfile)
        XCTAssertEqual(next.authorityGeneration, 2)
        XCTAssertEqual(try storedFormat(), CaptureIngestParseFormat.claudeCustomProfile.rawValue)
        XCTAssertEqual(try dryRun(laterEpoch).current.parseFormat, .claudeCustomProfile)
        XCTAssertEqual(try history().map(\.authorityGeneration), [1, 2])
        XCTAssertEqual(try history().map(\.approvedEpoch), [epoch, nextEpoch])
        XCTAssertEqual(try provision(parseFormat: .claudeCustomProfile, initialEpoch: nextEpoch), next)
        XCTAssertEqual(try history().count, 2)
        try reopen()
        XCTAssertEqual(try binding()?.parseFormat, .claudeCustomProfile)
        XCTAssertEqual(try binding()?.authorityGeneration, 2)
        XCTAssertEqual(try history().map(\.approvedEpoch), [epoch, nextEpoch])
    }

    func testLegacySchemaAddsNullableFormatWithoutBackfillOrAuthorityPromotion() throws {
        let capture = try manifest()
        let published = try publication(capture)
        try seed(published, ordinal: 1)
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = 'index_ready'") }
        try installLegacyRegistry()
        try writer.migrate()
        try writer.migrate()
        guard try requireFormatColumn() else { return }
        try writer.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(capture_ingest_source_registry)")
            let column = try XCTUnwrap(columns.first { ($0["name"] as String) == "parse_format" })
            XCTAssertEqual(column["notnull"] as Int, 0)
            XCTAssertNil(column["dflt_value"] as String?)
        }
        XCTAssertNil(try storedFormat())
        assertRegistryError(.parseFormatNotProvisioned) { try self.binding() }
        XCTAssertEqual(try eligibility(capture), .quarantined(.parseFormatNotProvisioned))
        assertRegistryError(.parseFormatNotProvisioned) { try self.provision(parseFormat: .claudeDefault) }
        assertRegistryError(.parseFormatNotProvisioned) { try self.dryRun(self.nextEpoch) }
        assertRegistryError(.parseFormatNotProvisioned) {
            try self.approve(self.nextEpoch, expectedEpoch: self.epoch, generation: 1)
        }
        XCTAssertEqual(try history().map(\.approvedEpoch), [epoch])
        XCTAssertEqual(try history().map(\.authorityGeneration), [1])
        XCTAssertEqual(try count("capture_ingest_source_registry"), 1)
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try writer.read {
            try CaptureIngestLedger.entry($0, publicationSHA256: published.sha256(), parserRevision: "parser-1")?.status
        }, .indexReady)
        try reopen()
        XCTAssertNil(try storedFormat())
        XCTAssertEqual(try eligibility(capture), .quarantined(.parseFormatNotProvisioned))
        XCTAssertEqual(try history().map(\.approvedEpoch), [epoch])
    }

    func testNullFormatCannotBeInferredFromRootSpellingOrManifestSource() throws {
        for (source, configuredRoot) in [
            (SourceName.claudeCode, "/fictional-client/.claude/projects"),
            (.claudeCode, "/fictional-client/custom-profile/projects"),
            (.codex, "/fictional-client/.codex/sessions"),
        ] {
            try installLegacyRegistry(source: source, configuredRoot: configuredRoot)
            try writer.migrate()
            guard try requireFormatColumn() else { return }
            let capture = try manifest(source: source.rawValue, locator: configuredRoot + "/session.jsonl")
            XCTAssertNil(try storedFormat())
            assertRegistryError(.parseFormatNotProvisioned) { try self.binding() }
            XCTAssertEqual(try eligibility(capture), .quarantined(.parseFormatNotProvisioned))
            XCTAssertNil(try storedFormat())
            XCTAssertEqual(try history().map(\.authorityGeneration), [1])
        }
    }

    func testUnknownStoredParseFormatFailsClosedWithoutRepair() throws {
        _ = try provision(parseFormat: .claudeDefault)
        guard try requireFormatColumn() else { return }
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_source_registry SET parse_format = 'futureFormat'") }
        assertRegistryError(.invalidStoredBinding) { try self.binding() }
        assertRegistryError(.invalidStoredBinding) { try self.eligibility(self.manifest()) }
        assertRegistryError(.invalidStoredBinding) { try self.provision(parseFormat: .claudeDefault) }
        assertRegistryError(.invalidStoredBinding) { try self.dryRun(self.nextEpoch) }
        assertRegistryError(.invalidStoredBinding) {
            try self.approve(self.nextEpoch, expectedEpoch: self.epoch, generation: 1)
        }
        XCTAssertEqual(try storedFormat(), "futureFormat")
        XCTAssertEqual(try history().map(\.authorityGeneration), [1])
    }

    func testStoredSourceFormatMismatchCannotBecomeEligibleOrAdvanceEpoch() throws {
        _ = try provision(parseFormat: .claudeCustomProfile)
        guard try requireFormatColumn() else { return }
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_source_registry SET parse_format = 'codex'") }
        assertRegistryError(.invalidStoredBinding) { try self.binding() }
        assertRegistryError(.invalidStoredBinding) { try self.eligibility(self.manifest()) }
        assertRegistryError(.invalidStoredBinding) {
            try self.approve(self.nextEpoch, expectedEpoch: self.epoch, generation: 1)
        }
        XCTAssertEqual(try storedFormat(), "codex")
        XCTAssertEqual(try history().map(\.authorityGeneration), [1])
    }

    func testUnconfiguredRootsDoNotBlockUnrelatedBindingsButStillConstrainMappings() throws {
        let approved = try provision(parseFormat: .claudeCustomProfile)
        let unconfiguredRoot = root + "-unconfigured"
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO capture_ingest_source_registry(
                    machine_id, source_instance_id, source, configured_root, approved_epoch, authority_generation
                ) VALUES (?, ?, 'claude-code', ?, ?, 1)
                """, arguments: [machine, nextEpoch, unconfiguredRoot, epoch])
            try db.execute(sql: """
                INSERT INTO capture_ingest_epoch_history(
                    machine_id, source_instance_id, previous_epoch, approved_epoch, authority_generation
                ) VALUES (?, ?, NULL, ?, 1)
                """, arguments: [machine, nextEpoch, epoch])
        }
        XCTAssertEqual(try eligibility(manifest()), .eligible(approved))
        _ = try provision(
            instanceID: laterEpoch, parseFormat: .claudeDefault, configuredRoot: root + "-unrelated"
        )
        assertRegistryError(.overlappingRoot) {
            try self.provision(
                instanceID: UUID().uuidString, parseFormat: .claudeDefault,
                configuredRoot: unconfiguredRoot + "/nested"
            )
        }
        let legacyCapture = try manifest(locator: unconfiguredRoot + "/session.jsonl")
        XCTAssertEqual(try eligibility(legacyCapture, instanceID: nextEpoch), .quarantined(.parseFormatNotProvisioned))
        XCTAssertEqual(try eligibility(manifest()), .eligible(approved))
        try writer.write {
            try $0.execute(sql: """
                UPDATE capture_ingest_source_registry SET configured_root = ? WHERE source_instance_id = ?
                """, arguments: [root + "/nested", nextEpoch])
        }
        XCTAssertEqual(try eligibility(manifest(locator: root + "/nested/session.jsonl")), .quarantined(.ambiguousSourceMapping))
        try writer.write {
            try $0.execute(sql: """
                UPDATE capture_ingest_epoch_history SET approved_epoch = ? WHERE source_instance_id = ?
                """, arguments: [nextEpoch, nextEpoch])
        }
        assertRegistryError(.invalidStoredBinding) { try self.eligibility(self.manifest()) }
    }

    private func provision(
        machineID: String? = nil, instanceID: String? = nil, source: SourceName = .claudeCode,
        parseFormat: CaptureIngestParseFormat? = nil, configuredRoot: String? = nil, initialEpoch: String? = nil
    ) throws -> CaptureIngestSourceBinding {
        try writer.write { try CaptureIngestSourceRegistry.provision(
            $0, machineID: machineID ?? machine, sourceInstanceID: instanceID ?? instance,
            source: source, parseFormat: parseFormat ?? (source == .codex ? .codex : .claudeDefault),
            configuredRoot: configuredRoot ?? root, initialEpoch: initialEpoch ?? epoch
        ) }
    }

    private func binding() throws -> CaptureIngestSourceBinding? {
        try writer.read { try CaptureIngestSourceRegistry.binding($0, machineID: machine, sourceInstanceID: instance) }
    }

    private func history() throws -> [CaptureIngestEpochTransition] {
        try writer.read { try CaptureIngestSourceRegistry.history($0, machineID: machine, sourceInstanceID: instance) }
    }

    private func dryRun(_ candidate: String) throws -> CaptureIngestEpochDryRun {
        try writer.read { try CaptureIngestSourceRegistry.dryRunEpoch(
            $0, machineID: machine, sourceInstanceID: instance, candidateEpoch: candidate
        ) }
    }

    private func approve(_ candidate: String, expected: CaptureIngestSourceBinding) throws -> CaptureIngestSourceBinding {
        try approve(candidate, expectedEpoch: expected.approvedEpoch, generation: expected.authorityGeneration)
    }

    private func approve(_ candidate: String, expectedEpoch: String, generation: Int64) throws -> CaptureIngestSourceBinding {
        try writer.write { try CaptureIngestSourceRegistry.approveEpoch(
            $0, machineID: machine, sourceInstanceID: instance, candidateEpoch: candidate,
            expectedEpoch: expectedEpoch, expectedAuthorityGeneration: generation
        ) }
    }

    private func eligibility(
        _ capture: ArchiveSourceManifest, collectorEpoch: String? = nil, instanceID: String? = nil
    ) throws -> CaptureIngestEligibility {
        let envelope = try publication(capture, collectorEpoch: collectorEpoch, instanceID: instanceID)
        return try writer.read {
            try CaptureIngestSourceRegistry.eligibility($0, publication: envelope, verifiedManifest: capture)
        }
    }

    private func publication(
        _ capture: ArchiveSourceManifest, collectorEpoch: String? = nil, instanceID: String? = nil, digest: String? = nil
    ) throws -> CollectorPublicationEnvelope {
        try CollectorPublicationEnvelope(
            machineID: machine, sourceInstanceID: instanceID ?? instance, collectorEpoch: collectorEpoch ?? epoch,
            sequence: 1, manifestSHA256: digest ?? ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(capture))
        )
    }

    private func manifest(
        machineID: String? = nil, source: String = "claude-code", locator: String? = nil, sessionID: String? = nil
    ) throws -> ArchiveSourceManifest {
        try ArchiveSourceManifest(
            captureID: String(repeating: "a", count: 64), machineID: machineID ?? machine,
            source: source, locator: locator ?? root + "/session.jsonl", sessionID: sessionID,
            capturedAt: "2026-09-05T12:00:00.000Z",
            generation: ArchiveSourceGeneration(device: 1, inode: 2, size: 0, mtimeNs: 1, ctimeNs: 1, mode: 0o100600),
            wholeSourceSHA256: ArchiveV2Hash.sha256(Data()), rawByteCount: 0, chunks: [],
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: ["session.jsonl"])
        )
    }

    private func seed(_ publication: CollectorPublicationEnvelope, ordinal: Int64, parser: String = "parser-1", requested: String? = nil) throws {
        let ack = try CollectorPublicationACK(
            serverID: "hq", journalID: journal, arrivalOrdinal: ordinal,
            publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256,
            storedAt: "2026-09-05T12:00:00.000Z"
        )
        let record = try CollectorPublicationAcceptanceRecord(publication: publication, ack: ack)
        let page = try CollectorPublicationPage(
            items: [record], afterCursor: CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: ordinal).encoded(),
            hasMore: false
        )
        try writer.write { try CaptureIngestLedger.accept(
            $0, page: page, requestedCursor: requested, serverID: "hq", parserRevision: parser
        ) }
    }

    private func reopen() throws {
        writer = nil
        writer = try EngramDatabaseWriter(path: directory.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
    }

    private func requireSchema(file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let exists = try writer.read {
            try $0.tableExists("capture_ingest_source_registry") && $0.tableExists("capture_ingest_epoch_history")
        }
        XCTAssertTrue(exists, "registry migration is required", file: file, line: line)
        return exists
    }

    private func requireFormatColumn(file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let exists = try writer.read {
            try Row.fetchAll($0, sql: "PRAGMA table_info(capture_ingest_source_registry)")
                .contains { ($0["name"] as String) == "parse_format" }
        }
        XCTAssertTrue(exists, "nullable parse format migration is required", file: file, line: line)
        return exists
    }

    private func storedFormat(instanceID: String? = nil) throws -> String? {
        try writer.read {
            let row = try Row.fetchOne($0, sql: """
                SELECT parse_format FROM capture_ingest_source_registry WHERE machine_id = ? AND source_instance_id = ?
                """, arguments: [machine, instanceID ?? instance])
            return row?["parse_format"]
        }
    }

    private func installLegacyRegistry(source: SourceName = .claudeCode, configuredRoot: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                DROP TABLE capture_ingest_epoch_history;
                DROP TABLE capture_ingest_source_registry;
                CREATE TABLE capture_ingest_source_registry (
                    machine_id TEXT NOT NULL, source_instance_id TEXT NOT NULL, source TEXT NOT NULL,
                    configured_root TEXT NOT NULL, approved_epoch TEXT NOT NULL,
                    authority_generation INTEGER NOT NULL CHECK (authority_generation > 0),
                    created_at TEXT NOT NULL DEFAULT (datetime('now')), updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                    PRIMARY KEY (machine_id, source_instance_id), UNIQUE (machine_id, source, configured_root)
                );
                CREATE TABLE capture_ingest_epoch_history (
                    machine_id TEXT NOT NULL, source_instance_id TEXT NOT NULL, previous_epoch TEXT,
                    approved_epoch TEXT NOT NULL, authority_generation INTEGER NOT NULL CHECK (authority_generation > 0),
                    approved_at TEXT NOT NULL DEFAULT (datetime('now')),
                    PRIMARY KEY (machine_id, source_instance_id, authority_generation),
                    UNIQUE (machine_id, source_instance_id, approved_epoch),
                    FOREIGN KEY (machine_id, source_instance_id)
                        REFERENCES capture_ingest_source_registry(machine_id, source_instance_id)
                );
                """)
            try db.execute(sql: """
                INSERT INTO capture_ingest_source_registry(
                    machine_id, source_instance_id, source, configured_root, approved_epoch, authority_generation
                ) VALUES (?, ?, ?, ?, ?, 1)
                """, arguments: [machine, instance, source.rawValue, configuredRoot ?? root, epoch])
            try db.execute(sql: """
                INSERT INTO capture_ingest_epoch_history(
                    machine_id, source_instance_id, previous_epoch, approved_epoch, authority_generation
                ) VALUES (?, ?, NULL, ?, 1)
                """, arguments: [machine, instance, epoch])
        }
    }

    private func count(_ table: String) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private func assertRegistryError<T>(
        _ expected: CaptureIngestSourceRegistryError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestSourceRegistryError, expected, file: file, line: line)
        }
    }
}

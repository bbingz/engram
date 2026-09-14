import EngramCoreRead
import EngramCoreWrite
import XCTest

final class CaptureIngestIdentityTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    func testFrozenCanonicalEncodingUsesExistingImportNamespace() throws {
        let identity = try makeIdentity(nativeID: "session:one/二")
        let component = "WyJjbGF1ZGUtY29kZSIsInNlc3Npb246b25lL-S6jCJd"
        XCTAssertEqual(identity.peer, "capture-v1.\(machine).\(instance)")
        XCTAssertEqual(try identity.proposedSessionID(), "remote:capture-v1.\(machine).\(instance):\(component)")
        XCTAssertEqual(
            try identity.proposedSessionID(),
            ImportRepo.importedLocalId(peer: identity.peer, sessionId: component)
        )
        XCTAssertFalse(try identity.proposedSessionID().hasPrefix("remote://"))
        XCTAssertFalse(identity.peer == "hq")
    }

    func testMachineInstanceSourceAndNativeIDAreSeparateCollisionDomains() throws {
        let base = try makeIdentity(nativeID: "x:y")
        let otherMachine = try CaptureIngestIdentity(
            machineID: instance, sourceInstanceID: instance, source: .claudeCode, nativeID: "x:y"
        )
        let otherInstance = try CaptureIngestIdentity(
            machineID: machine, sourceInstanceID: machine, source: .claudeCode, nativeID: "x:y"
        )
        let otherSource = try CaptureIngestIdentity(
            machineID: machine, sourceInstanceID: instance, source: .codex, nativeID: "x:y"
        )
        let otherNative = try makeIdentity(nativeID: "x:y:")
        let identities = [base, otherMachine, otherInstance, otherSource, otherNative]
        XCTAssertEqual(try Set(identities.map { try $0.proposedSessionID() }).count, identities.count)
    }

    func testParentMappingRetainsProvenanceAndChangesOnlyNativeID() throws {
        let child = try makeIdentity(nativeID: "child")
        let parent = try child.mapping(nativeID: "parent")
        XCTAssertEqual(parent, try makeIdentity(nativeID: "parent"))
        XCTAssertEqual(child.peer, parent.peer)
        XCTAssertNotEqual(try child.proposedSessionID(), try parent.proposedSessionID())
    }

    func testIdentityPreservesExactNativeCharactersWithoutPathOrUnicodeNormalization() throws {
        let ids = ["a/b", "a:b", "a\\b", "a b", "a%2Fb", "é", "e\u{301}", "a\"b", "a\nb"]
        let identities = try ids.map { try makeIdentity(nativeID: $0) }
        XCTAssertEqual(try Set(identities.map { try $0.proposedSessionID() }).count, ids.count)
        XCTAssertNotEqual(try makeIdentity(nativeID: "é"), try makeIdentity(nativeID: "e\u{301}"))
        for (native, identity) in zip(ids, identities) {
            XCTAssertEqual(Array(identity.nativeID.utf8), Array(native.utf8))
        }
    }

    func testRejectsNoncanonicalOrMissingMachineIdentity() throws {
        for invalid in ["", "hostname", machine.lowercased(), " \(machine)", "\(machine)\n"] {
            XCTAssertThrowsError(try CaptureIngestIdentity(
                machineID: invalid, sourceInstanceID: instance, source: .codex, nativeID: "id"
            )) { XCTAssertEqual($0 as? CaptureIngestIdentityError, .invalidMachineID) }
        }
    }

    func testRejectsNoncanonicalOrMissingSourceInstanceIdentity() throws {
        for invalid in ["", "legacy-archive-v2", instance.lowercased(), "\(instance)/root"] {
            XCTAssertThrowsError(try CaptureIngestIdentity(
                machineID: machine, sourceInstanceID: invalid, source: .codex, nativeID: "id"
            )) { XCTAssertEqual($0 as? CaptureIngestIdentityError, .invalidSourceInstanceID) }
        }
    }

    func testRejectsEmptyOrNulNativeIdentityIncludingParentMapping() throws {
        for invalid in ["", "a\0b"] {
            XCTAssertThrowsError(try makeIdentity(nativeID: invalid)) {
                XCTAssertEqual($0 as? CaptureIngestIdentityError, .invalidNativeID)
            }
            let identity = try makeIdentity(nativeID: "valid")
            XCTAssertThrowsError(try identity.mapping(nativeID: invalid))
        }
    }

    private func makeIdentity(nativeID: String) throws -> CaptureIngestIdentity {
        try CaptureIngestIdentity(machineID: machine, sourceInstanceID: instance, source: .claudeCode, nativeID: nativeID)
    }
}

import Foundation
import EngramCoreRead

public enum CaptureIngestIdentityError: Error, Equatable {
    case invalidMachineID
    case invalidSourceInstanceID
    case invalidNativeID
}

/// Stable provenance, kept independently of the physical replay path.
public struct CaptureIngestIdentity: Equatable, Sendable {
    public let machineID: String
    public let sourceInstanceID: String
    public let source: SourceName
    public let nativeID: String

    public init(machineID: String, sourceInstanceID: String, source: SourceName, nativeID: String) throws {
        guard UUID(uuidString: machineID)?.uuidString == machineID else {
            throw CaptureIngestIdentityError.invalidMachineID
        }
        guard UUID(uuidString: sourceInstanceID)?.uuidString == sourceInstanceID else {
            throw CaptureIngestIdentityError.invalidSourceInstanceID
        }
        guard !nativeID.isEmpty, !nativeID.utf8.contains(0) else {
            throw CaptureIngestIdentityError.invalidNativeID
        }
        self.machineID = machineID
        self.sourceInstanceID = sourceInstanceID
        self.source = source
        self.nativeID = nativeID
    }

    public var peer: String { "capture-v1.\(machineID).\(sourceInstanceID)" }

    /// This proposes the ID for a new identity; a proved alias binding takes
    /// precedence. Never infer an existing session match from this ID alone.
    public func proposedSessionID() throws -> String {
        let component = try ArchiveCanonicalJSON.encode([source.rawValue, nativeID])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return ImportRepo.importedLocalId(peer: peer, sessionId: component)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.machineID == rhs.machineID && lhs.sourceInstanceID == rhs.sourceInstanceID
            && lhs.source == rhs.source && lhs.nativeID.utf8.elementsEqual(rhs.nativeID.utf8)
    }

    public func mapping(nativeID: String) throws -> CaptureIngestIdentity {
        try CaptureIngestIdentity(
            machineID: machineID, sourceInstanceID: sourceInstanceID, source: source, nativeID: nativeID
        )
    }
}

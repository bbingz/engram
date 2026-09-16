import EngramCoreRead
import Foundation

extension ArchiveLocatorClassifier {
    public static func classify(
        adapter: any SessionAdapter,
        locator: String
    ) async throws -> ArchiveLocatorClassification {
        try Task.checkCancellation()
        if isVirtual(locator) {
            return .unsupportedVirtual
        }
        guard let adapter = adapter as? any ExactArchiveSourceAdapter else {
            return .unsupportedAdapter
        }
        let descriptor = try await adapter.archiveSourceDescriptor(locator: locator)
        try Task.checkCancellation()
        return classify(descriptor: descriptor, enumeratedLocator: locator)
    }
}

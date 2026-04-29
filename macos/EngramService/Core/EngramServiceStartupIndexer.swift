import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

public enum EngramServiceStartupIndexer {
    @discardableResult
    public static func start(
        gate: ServiceWriterGate,
        adapters: [any SessionAdapter] = DefaultSessionAdapters.make()
    ) -> Task<Void, Never> {
        Task {
            do {
                let indexed = try await indexOnce(gate: gate, adapters: adapters)
                ServiceLogger.notice("startup index completed: indexed=\(indexed)", category: .runner)
                print(#"{"event":"startup_index","indexed":\#(indexed)}"#)
                fflush(stdout)
            } catch is CancellationError {
                ServiceLogger.info("startup index cancelled", category: .runner)
            } catch {
                ServiceLogger.error("startup index failed", category: .runner, error: error)
                print(#"{"event":"error","message":"startup index failed: \#(Self.escape(error.localizedDescription))"}"#)
                fflush(stdout)
            }
        }
    }

    @discardableResult
    public static func indexOnce(
        gate: ServiceWriterGate,
        adapters: [any SessionAdapter] = DefaultSessionAdapters.make()
    ) async throws -> Int {
        let result = try await gate.performWriteCommand(name: "startup_index") { writer in
            let sink = DatabaseWriterIndexingSink(writer: writer)
            let indexer = SwiftIndexer(sink: sink, adapters: adapters, authoritativeNode: "local")
            return try await indexer.indexAll()
        }
        return result.value
    }

    private static func escape(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? #""startup index failed""#
        return String(encoded.dropFirst().dropLast())
    }
}

private final class DatabaseWriterIndexingSink: IndexingWriteSink {
    private let writer: EngramDatabaseWriter

    init(writer: EngramDatabaseWriter) {
        self.writer = writer
    }

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        try writer.write { db in
            try SessionBatchUpsert(db: db).upsertBatch(snapshots, reason: reason)
        }
    }
}

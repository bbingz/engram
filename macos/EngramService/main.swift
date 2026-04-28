import Foundation
import EngramServiceCore

Task {
    do {
        try await EngramServiceRunner.run()
    } catch {
        ServiceLogger.error("EngramService failed to run", category: .runner, error: error)
        fputs("EngramService failed: \(error)\n", stderr)
        exit(1)
    }
}

dispatchMain()

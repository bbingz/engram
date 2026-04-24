import Foundation
import EngramServiceCore

Task {
    do {
        try await EngramServiceRunner.run()
    } catch {
        fputs("EngramService failed: \(error)\n", stderr)
        exit(1)
    }
}

dispatchMain()

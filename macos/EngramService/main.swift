import Foundation
import Dispatch
import EngramServiceCore

let serviceTask = Task {
    do {
        try await EngramServiceRunner.run()
        exit(0)
    } catch {
        // writerBusy means another EngramService instance already owns the
        // single-writer lock (and therefore the socket). Exiting is intentional
        // and not an error condition: there must be exactly one writer/socket
        // owner per database. A read-only "degraded" fallback is deliberately
        // not provided here because it would have to bind the same Unix socket
        // the live owner is already serving, which the bind would reject anyway.
        // We exit 0 in that case so supervisors don't treat the lost race as a
        // crash and enter a restart loop. All other service errors are real
        // failures and exit 1.
        if let message = engramServiceWriterBusyMessage(error) {
            ServiceLogger.notice(
                "EngramService deferring to existing writer (another instance owns the lock): \(message)",
                category: .runner
            )
            fputs("EngramService: another instance owns the writer lock; exiting.\n", stderr)
            exit(0)
        }
        ServiceLogger.error("EngramService failed to run", category: .runner, error: error)
        fputs("EngramService failed: \(error)\n", stderr)
        exit(1)
    }
}

let signalSources = installTerminationSignalHandlers(serviceTask: serviceTask)
withExtendedLifetime(signalSources) {
    dispatchMain()
}

private func installTerminationSignalHandlers(serviceTask: Task<Void, Never>) -> [DispatchSourceSignal] {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    configureTerminationSignalSource(termSource, signalNumber: SIGTERM, serviceTask: serviceTask)

    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    configureTerminationSignalSource(intSource, signalNumber: SIGINT, serviceTask: serviceTask)

    return [termSource, intSource]
}

private func configureTerminationSignalSource(
    _ source: DispatchSourceSignal,
    signalNumber: Int32,
    serviceTask: Task<Void, Never>
) {
    source.setEventHandler {
        ServiceLogger.notice(
            "EngramService received termination signal \(signalNumber); beginning graceful shutdown",
            category: .runner
        )
        serviceTask.cancel()
    }
    source.resume()
}

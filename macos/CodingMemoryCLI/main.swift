// macos/CodingMemoryCLI/main.swift
// CodingMemory stdio bridge: stdin/stdout ↔ /tmp/coding-memory.sock
// MCP stdio transport: newline-delimited JSON-RPC
import Foundation
import Network

let socketPath = "/tmp/coding-memory.sock"

class StdioBridge {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "mcp.cli", qos: .userInteractive)

    func run() {
        do {
            try connect()
        } catch {
            fputs("CodingMemoryCLI: connect failed: \(error)\n", stderr)
            exit(1)
        }

        // Read stdin line by line, forward to socket, print response
        while let line = readLine(strippingNewline: false) {
            guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
            let response = sendAndReceive(data)
            if let response {
                FileHandle.standardOutput.write(response)
                if !(response.last == UInt8(ascii: "\n")) {
                    FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
                }
            }
        }
    }

    private func connect() throws {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        let ready = DispatchSemaphore(value: 0)
        var connectError: Error?

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let err):
                connectError = err
                ready.signal()
            default:
                break
            }
        }
        conn.start(queue: queue)
        ready.wait()

        if let err = connectError {
            throw err
        }
    }

    private func sendAndReceive(_ data: Data) -> Data? {
        let sendDone = DispatchSemaphore(value: 0)
        connection?.send(content: data, completion: .contentProcessed { _ in
            sendDone.signal()
        })
        sendDone.wait()

        // Receive response (read until we get a complete JSON line)
        return receiveUntilNewline()
    }

    private func receiveUntilNewline() -> Data? {
        var buffer = Data()
        let done = DispatchSemaphore(value: 0)

        func readMore() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, _ in
                if let data = content {
                    buffer.append(data)
                    // Check if we have a complete line
                    if buffer.contains(UInt8(ascii: "\n")) {
                        done.signal()
                        return
                    }
                }
                if isComplete {
                    done.signal()
                    return
                }
                readMore()  // keep reading
            }
        }

        readMore()
        done.wait()

        return buffer.isEmpty ? nil : buffer
    }
}

let bridge = StdioBridge()
bridge.run()

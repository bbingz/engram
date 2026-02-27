import Foundation
import Network

// CodingMemoryCLI — stdio bridge to MCPServer via Unix socket HTTP
// Reads JSON-RPC lines from stdin, sends as HTTP POST /mcp, writes response to stdout.

let socketPath = "/tmp/coding-memory.sock"

// Read one line from stdin
func readStdinLine() -> String? {
    var line = ""
    while let char = readCharacter() {
        if char == "\n" { return line }
        line.append(char)
    }
    return line.isEmpty ? nil : line
}

func readCharacter() -> Character? {
    var byte = UInt8(0)
    let n = read(STDIN_FILENO, &byte, 1)
    guard n == 1 else { return nil }
    return Character(Unicode.Scalar(byte))
}

// Send one HTTP POST request and receive the response body
func sendRequest(_ jsonBody: String) -> String? {
    let bodyData = jsonBody.data(using: .utf8)!
    let httpRequest = [
        "POST /mcp HTTP/1.1",
        "Host: localhost",
        "Content-Type: application/json",
        "Content-Length: \(bodyData.count)",
        "Connection: keep-alive",
        "",
        jsonBody
    ].joined(separator: "\r\n")

    guard let requestData = httpRequest.data(using: .utf8) else { return nil }

    let endpoint = NWEndpoint.unix(path: socketPath)
    let conn = NWConnection(to: endpoint, using: .tcp)

    var responseBody: String? = nil
    let sema = DispatchSemaphore(value: 0)

    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            // Send request
            conn.send(content: requestData, completion: .contentProcessed({ error in
                if error != nil { sema.signal(); return }
                // Receive response
                receiveHTTPResponse(conn: conn) { body in
                    responseBody = body
                    sema.signal()
                }
            }))
        case .failed, .cancelled:
            sema.signal()
        default:
            break
        }
    }

    conn.start(queue: .global())
    sema.wait()
    conn.cancel()
    return responseBody
}

func receiveHTTPResponse(conn: NWConnection, completion: @escaping (String?) -> Void) {
    // Accumulate data until we have complete headers + body
    var accumulated = Data()

    func receiveMore() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data { accumulated.append(data) }

            // Try to parse headers
            let headerSep = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            if let sepRange = accumulated.range(of: headerSep) {
                let headerData = accumulated[..<sepRange.lowerBound]
                let headerStr = String(data: headerData, encoding: .utf8) ?? ""
                let bodyStart = sepRange.upperBound

                // Parse Content-Length
                var contentLength = 0
                for line in headerStr.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                        contentLength = Int(val) ?? 0
                    }
                }

                let bodyData = accumulated[bodyStart...]
                if bodyData.count >= contentLength {
                    let body = String(data: bodyData.prefix(contentLength), encoding: .utf8)
                    completion(body)
                    return
                }
            }

            if !isComplete && error == nil {
                receiveMore()
            } else {
                completion(nil)
            }
        }
    }

    receiveMore()
}

// Main loop: read stdin line by line, forward each as HTTP request, write response to stdout
while let line = readStdinLine() {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }

    if let response = sendRequest(trimmed) {
        print(response)
        fflush(stdout)
    }
}

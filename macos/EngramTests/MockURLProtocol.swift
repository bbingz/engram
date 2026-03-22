// macos/EngramTests/MockURLProtocol.swift
import Foundation

/// A URLProtocol subclass that intercepts all requests for testing.
/// Set `MockURLProtocol.requestHandler` before each test to control responses.
class MockURLProtocol: URLProtocol {
    /// Handler called for every intercepted request.
    /// Return the desired (HTTPURLResponse, Data?) tuple, or throw to simulate an error.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op: nothing to cancel
    }
}

/// Create a URLSession configured to use MockURLProtocol for all requests.
func createMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

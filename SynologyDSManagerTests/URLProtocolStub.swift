//
//  URLProtocolStub.swift
//  SynologyDSManagerTests
//
//  URLProtocol subclass that serves canned responses for tests. Register
//  it on a URLSessionConfiguration's `protocolClasses` and every request
//  the session makes is intercepted here rather than hitting the
//  network. Captured requests are exposed via `requests` so tests can
//  assert on what was actually sent.
//
//  This is how tests catch regressions like "did we remember to put
//  _sid in the POST body?" or "did we swap to the wrong HTTP method?"
//  — failures that otherwise only surface against a real NAS.
//

import Foundation

final class URLProtocolStub: URLProtocol {

    // MARK: - Per-test plumbing

    /// Decides what to return for a given request. Last write wins.
    /// Set from the test; cleared by `reset()`.
    nonisolated(unsafe) static var responder: ((URLRequest) -> Result<(Data, HTTPURLResponse), Error>)?

    /// Every request the stub has observed since the last `reset()`,
    /// in order. Tests index into this to assert on request shape.
    nonisolated(unsafe) static var requests: [URLRequest] = []

    /// Reset responder + captured requests between tests. Call from
    /// `setUp()` and `tearDown()`.
    static func reset() {
        responder = nil
        requests = []
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch responder(request) {
        case .success(let (data, response)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test convenience helpers

extension URLProtocolStub {

    /// Reply with the given JSON body and HTTP `status`. Enough for 95%
    /// of tests — we're testing a JSON API.
    static func respondWithJSON(_ json: String, status: Int = 200) {
        responder = { request in
            let data = json.data(using: .utf8) ?? Data()
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://unused.invalid")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return .success((data, response))
        }
    }

    /// Reply with a URLError. Useful for "connection refused" and
    /// timeout-style transport failures.
    static func respondWithError(_ code: URLError.Code) {
        responder = { _ in .failure(URLError(code)) }
    }

    /// Queue a sequence of JSON responses. The first captured request
    /// gets the first JSON, the second gets the second, etc. Tests that
    /// need a multi-step flow (authenticate → listTasks → pauseTask…)
    /// use this.
    static func respondWithJSONSequence(_ payloads: [String]) {
        var remaining = payloads
        responder = { request in
            let next = remaining.isEmpty ? "{}" : remaining.removeFirst()
            let data = next.data(using: .utf8) ?? Data()
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://unused.invalid")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return .success((data, response))
        }
    }

    /// Extract the form-encoded POST body from the request at `index`
    /// (0-based, in the order the stub observed them). `URLRequest`
    /// bodies can arrive either as a raw `httpBody` or as a
    /// `httpBodyStream`; URLSession uses the latter when submitted via
    /// `URLSession.data(for:)`, so we handle both.
    static func formBody(at index: Int) -> String? {
        guard index < requests.count else { return nil }
        let request = requests[index]

        if let body = request.httpBody, let string = String(data: body, encoding: .utf8) {
            return string
        }
        if let stream = request.httpBodyStream {
            return drainStream(stream)
        }
        return nil
    }

    /// Parse a form-encoded POST body into a `[key: value]` dictionary.
    /// Convenient for `XCTAssertEqual(body["_sid"], "abc")` rather than
    /// string-contains checks that would false-positive on substring
    /// collisions.
    static func formFields(at index: Int) -> [String: String] {
        guard let body = formBody(at: index) else { return [:] }
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = String(parts[1])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(parts[1])
            result[key] = value
        }
        return result
    }

    private static func drainStream(_ stream: InputStream) -> String? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}

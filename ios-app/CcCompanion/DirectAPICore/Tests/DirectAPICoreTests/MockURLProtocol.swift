import Foundation

/// 让测试拦截 URLSession.shared 的请求, 回放预先配置的响应 —— 测的是真实 AnthropicAdapter/
/// OpenAICompatAdapter.streamChat/testConnection 本身(通过它们内部真实调用的 URLSession.shared),
/// 不是另外复刻一份解析逻辑再测复刻品.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responseProvider: ((URLRequest) -> StubResponse)?
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []

    static var responseProvider: ((URLRequest) -> StubResponse)? {
        get { lock.withLock { _responseProvider } }
        set { lock.withLock { _responseProvider = newValue } }
    }

    static var capturedRequests: [URLRequest] {
        lock.withLock { _capturedRequests }
    }

    static func reset() {
        lock.withLock {
            _responseProvider = nil
            _capturedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._capturedRequests.append(request) }
        guard let provider = Self.responseProvider else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = provider(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

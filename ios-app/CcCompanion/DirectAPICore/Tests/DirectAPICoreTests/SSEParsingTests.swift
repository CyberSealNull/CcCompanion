import XCTest
@testable import DirectAPICore

/// 这些测试跑真实的 AnthropicAdapter/OpenAICompatAdapter.streamChat/testConnection(通过 URLProtocol
/// 拦截它们内部真实调用的 URLSession.shared) —— 不是另外复刻一份 SSE 解析逻辑再测复刻品.
final class SSEParsingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Anthropic

    func testAnthropicStreamChatConcatenatesTextDeltas() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start"}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":", "}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let adapter = AnthropicAdapter()
        var received = ""
        for try await delta in adapter.streamChat(messages: [DirectAPIMessage(role: "user", content: "hi")], system: "", apiKey: "sk-test", model: "claude-sonnet-5") {
            received += delta
        }
        XCTAssertEqual(received, "Hello, world")
    }

    func testAnthropicStreamChatIgnoresPingEvents() async throws {
        let sse = """
        event: ping
        data: {"type":"ping"}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}

        """
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let adapter = AnthropicAdapter()
        var received = ""
        for try await delta in adapter.streamChat(messages: [], system: "", apiKey: "sk-test", model: "claude-sonnet-5") {
            received += delta
        }
        XCTAssertEqual(received, "ok")
    }

    func testAnthropicStreamChatThrowsOnErrorEvent() async throws {
        let sse = """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"before"}}

        data: {"type":"error","error":{"type":"overloaded_error","message":"服务器繁忙"}}

        """
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let adapter = AnthropicAdapter()
        var received = ""
        do {
            for try await delta in adapter.streamChat(messages: [], system: "", apiKey: "sk-test", model: "claude-sonnet-5") {
                received += delta
            }
            XCTFail("expected the stream to throw on an error event")
        } catch let err as DirectAPIError {
            XCTAssertEqual(received, "before")
            guard case .server(_, let message) = err else { return XCTFail("expected .server case, got \(err)") }
            XCTAssertEqual(message, "服务器繁忙")
        }
    }

    func testAnthropicStreamChatClassifiesUnauthorized() async throws {
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 401, headers: [:], body: Data("{\"error\":{\"message\":\"invalid x-api-key\"}}".utf8))
        }
        let adapter = AnthropicAdapter()
        do {
            for try await _ in adapter.streamChat(messages: [], system: "", apiKey: "bad-key", model: "claude-sonnet-5") {}
            XCTFail("expected .unauthorized")
        } catch let err as DirectAPIError {
            XCTAssertEqual(err, .unauthorized)
        }
    }

    // MARK: - OpenAI-compatible

    func testOpenAICompatStreamChatConcatenatesAndStopsAtDone() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"He"}}]}

        data: {"choices":[{"delta":{"content":"llo"}}]}

        data: [DONE]

        data: {"choices":[{"delta":{"content":"should-not-appear"}}]}

        """
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let adapter = OpenAICompatAdapter(baseURL: "https://api.openai.com/v1")
        var received = ""
        for try await delta in adapter.streamChat(messages: [], system: "", apiKey: "sk-test", model: "gpt-4o") {
            received += delta
        }
        XCTAssertEqual(received, "Hello")
    }

    func testOpenAICompatStreamChatSkipsEmptyChoicesWithoutCrashing() async throws {
        let sse = """
        data: {"choices":[]}

        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: [DONE]

        """
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 200, headers: [:], body: Data(sse.utf8))
        }
        let adapter = OpenAICompatAdapter(baseURL: "https://api.openai.com/v1")
        var received = ""
        for try await delta in adapter.streamChat(messages: [], system: "", apiKey: "sk-test", model: "gpt-4o") {
            received += delta
        }
        XCTAssertEqual(received, "ok")
    }

    // MARK: - P0-3 安全边界: HTTPS 校验必须在构造 Authorization header 前失败

    func testOpenAICompatRejectsPlainHTTPBeforeAnyRequestIsSent() async {
        let secretKey = "sk-should-never-leave-the-device"
        MockURLProtocol.responseProvider = { _ in
            XCTFail("no HTTP request should ever be issued for a rejected baseURL")
            return MockURLProtocol.StubResponse(status: 500, headers: [:], body: Data())
        }
        let adapter = OpenAICompatAdapter(baseURL: "http://leaky-gateway.example.com")
        let result = await adapter.testConnection(apiKey: secretKey, model: "gpt-4o")
        guard case .failure(let err) = result else { return XCTFail("expected failure for a plain-http non-loopback baseURL") }
        XCTAssertEqual(err, .network(BaseURLValidationError.notHTTPS.errorDescription ?? ""))
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty, "rejected baseURL must not produce any network request")
    }

    func testOpenAICompatSendsBearerHeaderOnlyAfterHTTPSValidationPasses() async throws {
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 200, headers: [:], body: Data("{\"choices\":[]}".utf8))
        }
        let adapter = OpenAICompatAdapter(baseURL: "https://api.openai.com/v1")
        let result = await adapter.testConnection(apiKey: "sk-real-key", model: "gpt-4o")
        guard case .success = result else { return XCTFail("valid https baseURL should succeed") }
        let captured = MockURLProtocol.capturedRequests
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-real-key")
    }

    func testOpenAICompatAllowsLoopbackHTTPForLocalModelServers() async throws {
        MockURLProtocol.responseProvider = { _ in
            MockURLProtocol.StubResponse(status: 200, headers: [:], body: Data("{\"choices\":[]}".utf8))
        }
        // LM Studio / Ollama 常见本机部署场景.
        let adapter = OpenAICompatAdapter(baseURL: "http://localhost:11434/v1")
        let result = await adapter.testConnection(apiKey: "sk-local", model: "llama3")
        guard case .success = result else { return XCTFail("loopback http should be allowed") }
        XCTAssertFalse(MockURLProtocol.capturedRequests.isEmpty)
    }
}
// DirectAPIError 已在 DirectAPIClient.swift 声明 Equatable(编译器自动合成), 这里不用重复声明.

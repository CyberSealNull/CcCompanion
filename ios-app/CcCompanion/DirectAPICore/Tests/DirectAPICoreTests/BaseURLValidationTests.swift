import XCTest
@testable import DirectAPICore

final class BaseURLValidationTests: XCTestCase {
    func testHTTPSAccepted() {
        let result = DirectAPIClient.validateBaseURL("https://api.openai.com/v1")
        guard case .success(let url) = result else { return XCTFail("https should be accepted") }
        XCTAssertEqual(url.host, "api.openai.com")
    }

    func testPlainHTTPRejected() {
        let result = DirectAPIClient.validateBaseURL("http://my-llm-gateway.example.com")
        guard case .failure(let err) = result else { return XCTFail("plain http to a non-loopback host must be rejected") }
        XCTAssertEqual(err, .notHTTPS)
    }

    func testLoopbackHTTPAllowed_localhost() {
        let result = DirectAPIClient.validateBaseURL("http://localhost:11434")
        guard case .success = result else { return XCTFail("http://localhost should be allowed (LM Studio / local model server use case)") }
    }

    func testLoopbackHTTPAllowed_127001() {
        let result = DirectAPIClient.validateBaseURL("http://127.0.0.1:8000")
        guard case .success = result else { return XCTFail("http://127.0.0.1 should be allowed") }
    }

    func testLANHTTPRejected() {
        // 产品决策: 局域网 IP 不算 loopback 例外, 诉求等真用户提了再议.
        let result = DirectAPIClient.validateBaseURL("http://192.168.1.50:8080")
        guard case .failure(let err) = result else { return XCTFail("LAN http must still be rejected") }
        XCTAssertEqual(err, .notHTTPS)
    }

    func testEmptyHostRejected() {
        let result = DirectAPIClient.validateBaseURL("https:///v1")
        guard case .failure(let err) = result else { return XCTFail("empty host must be rejected") }
        XCTAssertEqual(err, .emptyHost)
    }

    func testUserInfoRejected() {
        let result = DirectAPIClient.validateBaseURL("https://user:pass@api.example.com")
        guard case .failure(let err) = result else { return XCTFail("URL userinfo must be rejected") }
        XCTAssertEqual(err, .hasUserInfo)
    }

    func testMalformedRejected() {
        let result = DirectAPIClient.validateBaseURL("not a url at all")
        guard case .failure(let err) = result else { return XCTFail("malformed string must be rejected") }
        XCTAssertEqual(err, .malformed)
    }

    func testWhitespaceTrimmed() {
        let result = DirectAPIClient.validateBaseURL("  https://api.openai.com/v1  ")
        guard case .success = result else { return XCTFail("surrounding whitespace should be trimmed before validation") }
    }
}
// BaseURLValidationError 是无关联值枚举, 编译器已自动合成 Equatable, 不用再手写.

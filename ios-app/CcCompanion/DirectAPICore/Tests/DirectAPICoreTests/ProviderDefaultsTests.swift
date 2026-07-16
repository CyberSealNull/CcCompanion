import XCTest
@testable import DirectAPICore

final class ProviderDefaultsTests: XCTestCase {
    func testAnthropicDefaultModel() {
        XCTAssertEqual(DirectAPIProvider.anthropic.defaultModel, "claude-sonnet-5")
    }

    func testOpenAICompatDefaultModel() {
        XCTAssertEqual(DirectAPIProvider.openAICompat.defaultModel, "gpt-5.6")
    }

    func testOtherIsBlankSlateOnOpenAICompatWire() {
        XCTAssertEqual(DirectAPIProvider.other.defaultModel, "")
        XCTAssertTrue(DirectAPIProvider.other.usesOpenAICompatWire)
        XCTAssertTrue(DirectAPIProvider.other.needsBaseURL)
        XCTAssertFalse(DirectAPIProvider.anthropic.usesOpenAICompatWire)
        XCTAssertTrue(DirectAPIProvider.openAICompat.usesOpenAICompatWire)
    }

    func testAllCasesCovered() {
        XCTAssertEqual(Set(DirectAPIProvider.allCases), [.anthropic, .openAICompat, .other])
    }

    func testErrorDescriptionsAreHumanReadable() {
        XCTAssertNotNil(DirectAPIError.missingKey.errorDescription)
        XCTAssertNotNil(DirectAPIError.unauthorized.errorDescription)
        XCTAssertNotNil(DirectAPIError.rateLimited.errorDescription)
        XCTAssertTrue((DirectAPIError.network("timeout").errorDescription ?? "").contains("timeout"))
    }
}
// DirectAPIProvider 是无关联值枚举, 编译器已自动合成 Hashable, 不用再手写.

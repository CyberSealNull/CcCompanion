import XCTest
@testable import DirectAPICore

/// 二审必测负例(P0-4): key 只进 Keychain, 不落 UserDefaults dump —— 之前只有静态 grep,
/// 这里换成真跑: 写入后 dump `UserDefaults.standard` 全量 key-value, 断言 key 内容不出现在任何值里.
final class SecureAPIKeyStoreTests: XCTestCase {
    private let store = SecureAPIKeyStore(service: "com.starryfield.cccompanion.tests", account: "ccc-direct-api-key-test")

    override func tearDown() {
        store.setApiKey(nil)
        super.tearDown()
    }

    func testKeyRoundTripsViaKeychainOnly() {
        let secret = "sk-test-should-never-leave-keychain-\(UUID().uuidString)"
        store.setApiKey(secret)
        XCTAssertEqual(store.apiKey, secret)
        XCTAssertTrue(store.hasApiKey)
    }

    func testKeyNeverLandsInUserDefaultsDump() {
        let secret = "sk-test-should-never-leave-keychain-\(UUID().uuidString)"
        store.setApiKey(secret)
        XCTAssertEqual(store.apiKey, secret)  // sanity: 确实存进去了(不是误测了个从没写入的空实现)

        let dump = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in dump {
            let text = String(describing: value)
            XCTAssertFalse(text.contains(secret), "API key 内容出现在 UserDefaults key \"\(key)\" 里")
        }
    }

    func testClearingKeyRemovesIt() {
        store.setApiKey("sk-temp-value")
        XCTAssertTrue(store.hasApiKey)
        store.setApiKey(nil)
        XCTAssertFalse(store.hasApiKey)
        XCTAssertNil(store.apiKey)
    }

    func testWhitespaceOnlyKeyTreatedAsCleared() {
        store.setApiKey("   ")
        XCTAssertFalse(store.hasApiKey)
    }
}

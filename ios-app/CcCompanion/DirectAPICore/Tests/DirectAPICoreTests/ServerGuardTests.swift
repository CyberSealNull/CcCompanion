import XCTest
@testable import DirectAPICore

/// 二审必测负例(P0-2): global `URLProtocol.registerClass` 只覆盖 `URLSession.shared`, 覆盖不了显式
/// `URLSession(configuration:)` —— 这是回炉一审漏掉、fresh Foundation 对照 probe 坐实的真因。
/// 这里不打真网络: 目标 host 统一指向 `127.0.0.1:1`(loopback 上几乎必然没有进程监听的端口), 命中 guard
/// 时 startLoading() 同步 fail、连 DNS/connect 都不会发生; 没命中 guard 时才会真的走到系统网络栈,
/// loopback 连不上会秒级 "connection refused"(不依赖沙盒有没有真实外网), 用错误 domain 是不是
/// "DirectAPIServerGuard" 区分"被我们的闸拦下"还是"漏网走了真连接"。
final class ServerGuardTests: XCTestCase {
    private let refusedTarget = URL(string: "http://127.0.0.1:1/probe")!

    override func setUp() {
        super.setUp()
        DirectAPIServerGuardProtocol.isActiveProvider = { false }
        DirectAPIServerGuardProtocol.guardedHostsProvider = { [] }
    }

    override func tearDown() {
        DirectAPIServerGuardProtocol.isActiveProvider = { false }
        DirectAPIServerGuardProtocol.guardedHostsProvider = { [] }
        super.tearDown()
    }

    private func assertIntercepted(_ session: URLSession, line: UInt = #line) async {
        do {
            _ = try await session.data(from: refusedTarget)
            XCTFail("expected DirectAPIServerGuard to intercept this request", line: line)
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "DirectAPIServerGuard", "wrong interceptor for this request", line: line)
        }
    }

    private func assertNotIntercepted(_ session: URLSession, line: UInt = #line) async {
        do {
            _ = try await session.data(from: refusedTarget)
            XCTFail("127.0.0.1:1 should never succeed — a listener would invalidate the test setup", line: line)
        } catch {
            let nsError = error as NSError
            XCTAssertNotEqual(nsError.domain, "DirectAPIServerGuard", "guard should not have seen this request", line: line)
        }
    }

    // MARK: - shared_hit (global registerClass 覆盖 URLSession.shared)

    func testSharedSessionIsCaptured() async {
        DirectAPIServerGuardProtocol.register()
        DirectAPIServerGuardProtocol.isActiveProvider = { true }
        DirectAPIServerGuardProtocol.guardedHostsProvider = { ["127.0.0.1"] }
        await assertIntercepted(URLSession.shared)
    }

    // MARK: - explicit_protocolClasses_hit (ccGuarded 工厂覆盖自建 session)

    func testCustomSessionViaFactoryIsCaptured() async {
        DirectAPIServerGuardProtocol.isActiveProvider = { true }
        DirectAPIServerGuardProtocol.guardedHostsProvider = { ["127.0.0.1"] }
        let session = URLSession(configuration: DirectAPIServerGuardProtocol.ccGuarded())
        await assertIntercepted(session)
    }

    // MARK: - registered_default_hit (回炉一审的真因: 不经工厂的自建 session 漏网)

    func testCustomSessionWithoutFactoryIsNotCaptured() async {
        DirectAPIServerGuardProtocol.register()
        DirectAPIServerGuardProtocol.isActiveProvider = { true }
        DirectAPIServerGuardProtocol.guardedHostsProvider = { ["127.0.0.1"] }
        // 故意不走 ccGuarded() —— 复现回炉一审的 bug 现场: 全局 registerClass 已调用,
        // 但这枚自建 default session 仍然漏网(这正是二审抓到、必须靠工厂修的那条).
        let session = URLSession(configuration: .default)
        await assertNotIntercepted(session)
    }

    // MARK: - 只在 directAPI 模式生效

    func testInactiveModeDoesNotIntercept() async {
        DirectAPIServerGuardProtocol.isActiveProvider = { false }
        DirectAPIServerGuardProtocol.guardedHostsProvider = { ["127.0.0.1"] }
        let session = URLSession(configuration: DirectAPIServerGuardProtocol.ccGuarded())
        await assertNotIntercepted(session)
    }

    // MARK: - 只拦已知 host, 不误伤 provider API 本身

    func testUnguardedHostPassesThrough() async {
        DirectAPIServerGuardProtocol.isActiveProvider = { true }
        DirectAPIServerGuardProtocol.guardedHostsProvider = { ["some-other-ccserver-host.example.com"] }
        let session = URLSession(configuration: DirectAPIServerGuardProtocol.ccGuarded())
        await assertNotIntercepted(session)
    }
}

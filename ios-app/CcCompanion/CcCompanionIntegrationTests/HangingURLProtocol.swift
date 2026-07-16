//
//  HangingURLProtocol.swift
//  CcCompanionIntegrationTests
//
//  P0 四审前置: 上一轮 code review 點名的硬門 ——「fake transport + 兩庫 fixture: 掛起響應 →
//  切模式 → 放行」端到端集成測試需要一個真正能"掛起"的假 transport, 不是
//  DirectAPICoreTests/MockURLProtocol 那種立刻同步回應的版本. startLoading() 收到請求後在 gate
//  上 await, 測試呼叫 release() 之前永遠不會回調 client —— 由此才能構造"響應還沒回來, 用戶已經
//  切了模式"這個時序.
//
//  不用 DispatchSemaphore.wait() 橋接 async gate: learnings/2026-07-13_自验证工具本身要先用负例
//  正例炼过再信 記過一次真事故 —— ChatStoreScopeSelfTest 第一版用 Task+semaphore 橋 async API,
//  在 App.init() 同步上下文直接卡死. 這裡改用 startLoading() 內起一個獨立 Task await actor gate,
//  不阻塞任何真線程.
//
//  经验证(cancel_probe.swift 现场跑过): Task.cancel() 会让 session.data(for:) 提前收到
//  NSURLErrorCancelled(-999), 不等这个协议真的回调 —— 所以本类只用于"不经 stopAndWait() 追踪"的
//  裸调用场景(测试直接调 vm.loadEarlier(), 不经 loadEarlierTracked()), 才能真正测到"响应延迟到达,
//  写去哪个 scope"这个属性, 不被 mode 切换顺带触发的 cancel 提前短路掉.

import Foundation

final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private actor Gate {
        private var isOpen = false
        private var openWaiters: [CheckedContinuation<Void, Never>] = []
        private var arrivedCount = 0
        private var arrivalWaiters: [(threshold: Int, cont: CheckedContinuation<Void, Never>)] = []

        func waitUntilOpen() async {
            if isOpen { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func open() {
            isOpen = true
            let waiters = openWaiters
            openWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func recordArrival() {
            arrivedCount += 1
            let ready = arrivalWaiters.filter { arrivedCount >= $0.threshold }
            arrivalWaiters.removeAll { arrivedCount >= $0.threshold }
            ready.forEach { $0.cont.resume() }
        }

        func waitForArrival(atLeast threshold: Int) async {
            if arrivedCount >= threshold { return }
            await withCheckedContinuation { arrivalWaiters.append((threshold, $0)) }
        }

        func reset() {
            isOpen = false
            openWaiters.removeAll()
            arrivedCount = 0
            arrivalWaiters.removeAll()
        }
    }

    private static let gate = Gate()
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

    /// 每个 test case 的 setUp()/tearDown() 都要跑一次 —— 这是进程级单例拦截点, 状态不清会串测试.
    /// 用 async 而不是 semaphore.wait() 桥接: learnings/2026-07-13_自验证工具本身要先用负例正例炼过
    /// 再信 记过 Task+semaphore 在同步上下文桥接 async 卡死的真事故, 这里测试文件本身 setUp/tearDown
    /// 都声明成 async, 没有理由再冒一次同样的险.
    static func reset() async {
        lock.withLock {
            _responseProvider = nil
            _capturedRequests = []
        }
        await gate.reset()
    }

    /// 测试在踢开操作之后调用它, 确定性地知道假请求真的已经打到 startLoading()(正在挂起),
    /// 才继续下一步切模式 —— 不靠 Task.sleep 猜时序. 带超时(默认 10s)是刻意加的安全网: 现场真的
    /// 撞过一次"被测函数走了本地缓存分支, 请求压根没发出"导致这里无限期挂起, 一条测试卡了 4 分钟
    /// 才被外层 build 超时打断 —— 有超时至少能在秒级内给出清楚的失败信息, 而不是拖到外层超时.
    /// 返回 false 代表超时(请求没在预期时间内到达), 调用方应该用 XCTFail 而不是让测试继续往下走.
    @discardableResult
    static func waitForRequestReceived(count: Int = 1, timeout: TimeInterval = 10) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await gate.waitForArrival(atLeast: count)
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// 放行所有正在挂起的请求(以及此后到达的请求, 因为 gate 打开后 isOpen 保持 true).
    static func release() async {
        await gate.open()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._capturedRequests.append(request) }
        Task {
            await Self.gate.recordArrival()
            await Self.gate.waitUntilOpen()
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
    }

    override func stopLoading() {}

    static func makeSession(timeout: TimeInterval = 30) -> URLSession {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [HangingURLProtocol.self]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

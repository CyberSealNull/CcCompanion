//
//  HangingURLProtocol.swift
//  CcCompanionIntegrationTests
//
//  Deterministic transport for tracked-operation lifecycle tests. Requests pause at
//  an async gate until release(), while cancellation and reset wake every waiter.

import Foundation

final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private actor Gate {
        private var isOpen = false
        private var openWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var cancelledOpenWaiters: Set<UUID> = []
        private var arrivedCount = 0
        private var arrivalWaiters: [UUID: (threshold: Int, cont: CheckedContinuation<Void, Error>)] = [:]
        private var cancelledArrivalWaiters: Set<UUID> = []

        func waitUntilOpen() async throws {
            if isOpen { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if isOpen {
                        continuation.resume()
                    } else if Task.isCancelled || cancelledOpenWaiters.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        openWaiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelOpenWaiter(id) }
            }
        }

        func open() {
            isOpen = true
            let waiters = Array(openWaiters.values)
            openWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
        }

        func recordArrival() {
            arrivedCount += 1
            let readyIds = arrivalWaiters.compactMap { id, waiter in
                arrivedCount >= waiter.threshold ? id : nil
            }
            let ready = readyIds.compactMap { arrivalWaiters.removeValue(forKey: $0)?.cont }
            ready.forEach { $0.resume() }
        }

        func waitForArrival(atLeast threshold: Int) async throws {
            if arrivedCount >= threshold { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if arrivedCount >= threshold {
                        continuation.resume()
                    } else if Task.isCancelled || cancelledArrivalWaiters.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        arrivalWaiters[id] = (threshold, continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancelArrivalWaiter(id) }
            }
        }

        func reset() {
            isOpen = false
            arrivedCount = 0
            let open = Array(openWaiters.values)
            let arrivals = arrivalWaiters.values.map(\.cont)
            openWaiters.removeAll(keepingCapacity: false)
            arrivalWaiters.removeAll(keepingCapacity: false)
            cancelledOpenWaiters.removeAll(keepingCapacity: false)
            cancelledArrivalWaiters.removeAll(keepingCapacity: false)
            open.forEach { $0.resume(throwing: CancellationError()) }
            arrivals.forEach { $0.resume(throwing: CancellationError()) }
        }

        private func cancelOpenWaiter(_ id: UUID) {
            if let continuation = openWaiters.removeValue(forKey: id) {
                continuation.resume(throwing: CancellationError())
            } else {
                cancelledOpenWaiters.insert(id)
            }
        }

        private func cancelArrivalWaiter(_ id: UUID) {
            if let continuation = arrivalWaiters.removeValue(forKey: id)?.cont {
                continuation.resume(throwing: CancellationError())
            } else {
                cancelledArrivalWaiters.insert(id)
            }
        }
    }

    private static let gate = Gate()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responseProvider: ((URLRequest) -> StubResponse)?
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []
    private let loadingLock = NSLock()
    private var loadingTask: Task<Void, Never>?

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
                do {
                    try await gate.waitForArrival(atLeast: count)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return false
                }
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
        let task = Task { [weak self] in
            guard let self else { return }
            await Self.gate.recordArrival()
            do {
                try await Self.gate.waitUntilOpen()
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled {
                    client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                }
                return
            }
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
        loadingLock.withLock { loadingTask = task }
    }

    override func stopLoading() {
        let task = loadingLock.withLock {
            let current = loadingTask
            loadingTask = nil
            return current
        }
        task?.cancel()
    }

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

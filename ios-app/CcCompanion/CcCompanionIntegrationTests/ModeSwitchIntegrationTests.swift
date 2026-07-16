//
//  ModeSwitchIntegrationTests.swift
//  CcCompanionIntegrationTests
//
//  End-to-end coverage for backend generation ownership, serialized transitions,
//  replacement task joining, scoped storage, and stale-result rejection.
//
//  環境警告: 這是 TEST_HOST 掛在 CcCompanion.app 裡跑的 unit test, ChatStore.shared 走的是
//  APP 真實 Application Support 路徑下的 ChatCache.db / ChatCacheDirectAPI.db(跟 App 手動啟動
//  时是同一份文件), 不是隔離的臨時庫. 所以每條測試的斷言只認"帶測試專屬 UUID 的那一筆記錄
//  是否出現在哪個 scope", 不假設庫是空的 —— 對已有真實資料(或其它測試殘留)保持健壯.

import XCTest
@testable import CcCompanion

private final class DirectStreamHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var continuations: [UUID: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var order: [UUID] = []

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func makeStream() -> AsyncThrowingStream<String, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            lock.lock()
            starts += 1
            continuations[id] = continuation
            order.append(id)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }
        }
    }

    func finishLatest(with text: String) {
        lock.lock()
        let continuation = order.last.flatMap { continuations[$0] }
        lock.unlock()
        continuation?.yield(text)
        continuation?.finish()
    }

    private func remove(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        order.removeAll { $0 == id }
        lock.unlock()
    }
}

@MainActor
final class ModeSwitchIntegrationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await HangingURLProtocol.reset()
        DirectAPIConfig.mode = .ccServer
    }

    override func tearDown() async throws {
        await HangingURLProtocol.reset()
        DirectAPIConfig.mode = .ccServer
        try await super.tearDown()
    }

    func testWaitForRequestReceivedReturnsFalseWhenNoRequestArrives() async {
        let result = await HangingURLProtocol.waitForRequestReceived(timeout: 0.05)

        XCTAssertFalse(result)
    }

    // MARK: - Fixtures

    private func seedAnchorMessage(idSuffix: String) -> ChatMessage {
        ChatMessage(
            ts: "1900-06-01T00:00:00.000Z",
            role: "user",
            text: "seed-anchor",
            source: nil,
            quotedTs: nil,
            quotedText: nil,
            attachmentUrl: nil,
            attachmentType: nil,
            attachmentFilename: nil,
            audioZh: nil,
            audioEn: nil,
            audioJa: nil,
            location: nil,
            metadata: nil,
            localId: "seed-anchor-\(idSuffix)"
        )
    }

    // 用 text 而不是 local_id 做唯一标记: StoredChatMessage.chatMessage() 重建 ChatMessage 时不传
    // localId(现场调试坐实过, 见 result 文件"过程记录") —— localId 是纯本地乐观发送态跟踪键, 服务器
    // 来源的历史记录读回来本来就该是 nil, 这是应用侧既有设计不是 bug. text 字段读写都真实保留, 拿它
    // 做断言锚点才靠得住.
    private func fixtureText(_ uniqueId: String) -> String { "hanging-fixture-\(uniqueId)" }

    private func historyResponseJSON(ts: String, uniqueId: String) -> Data {
        let payload: [String: Any] = [
            "ok": true,
            "records": [
                ["ts": ts, "role": "assistant", "text": fixtureText(uniqueId)] as [String: Any],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private func historyResponseJSON(ts: String, text: String) -> Data {
        let payload: [String: Any] = [
            "ok": true,
            "records": [
                ["ts": ts, "role": "assistant", "text": text] as [String: Any],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private func stubHistoryResponse(ts: String, uniqueId: String) {
        let body = historyResponseJSON(ts: ts, uniqueId: uniqueId)
        HangingURLProtocol.responseProvider = { _ in
            HangingURLProtocol.StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }
    }

    private func waitForTransitionToSettle(
        _ vm: ChatViewModel,
        after generation: Int,
        maxIterations: Int = 3000
    ) async {
        var i = 0
        while (vm.settledModeGeneration <= generation || vm.settledModeGeneration != vm.modeGeneration),
              i < maxIterations {
            await Task.yield()
            i += 1
        }
    }

    private func recordExists(in scope: ChatStoreScope, text: String) -> Bool {
        scope.before(ts: "9999-12-31T23:59:59.000Z", limit: 20000).contains { $0.text == text }
    }

    /// 每条测试用完自己的 fixture 就删干净 —— 这条测试跑在 TEST_HOST 挂的真实 App 进程里,
    /// ChatStore.shared 走的是真实 Application Support 路径下的 db 文件, 不清理的话下一轮测试
    /// (甚至下一次 xcodebuild test 调用)会在本地缓存里看到上一轮的 fixture, loadEarlier() 的
    /// "本地有更早记录就直接返回, 不打网络"分支会被提前命中, 请求永远不会真正发出 ——
    /// 这正是现场调试挖出的真实教训, 见 result 文件.
    /// id 用 `ts + role` 计算: StoredChatMessage 写入时 message.id 就是这个值(fixture 没设 local_id).
    private func cleanupFixture(ts: String, role: String = "assistant") {
        let id = ts + role
        ChatStore.shared.snapshot(.ccServer).delete(ids: [id])
        ChatStore.shared.snapshot(.directAPI).delete(ids: [id])
    }

    private func waitForStreamStarts(_ harness: DirectStreamHarness, count: Int) async -> Bool {
        var i = 0
        while harness.startCount < count && i < 3000 {
            await Task.yield()
            i += 1
        }
        return harness.startCount >= count
    }

    // MARK: - fixed/buggy 两种"响应到达时落哪个 scope"实现, 正例负例共用
    //
    // fixed 冻结 scope 在网络 await 之前, buggy 在 await 之后才重新读 ambient DirectAPIConfig.mode ——
    // 后者就是 learnings/2026-07-13_运行时computed路由跨await会串库 点名的原始 bug 模式, 不是另外
    // 编一份逻辑, snapshot()/upsert() 都是真实 ChatStore 生产 API, 只是刻意在错误的时间点调用它.

    private func fixedFetchAndStore(url: URL, client: ChatNetworkClient) async throws {
        let store = ChatStore.shared.snapshot(DirectAPIConfig.mode)
        let records = try await client.fetchHistory(url: url)
        store.upsert(records)
    }

    private func buggyFetchAndStore(url: URL, client: ChatNetworkClient) async throws {
        let records = try await client.fetchHistory(url: url)
        ChatStore.shared.snapshot(DirectAPIConfig.mode).upsert(records)
    }

    // MARK: - Tracked operation lifecycle

    /// 挂起 fake transport 的响应 → 用户切模式(ccServer → directAPI) → 放行 →
    /// 断言旧响应不落新模式库、UI 状态(vm.messages)不串.
    func testTrackedLoadEarlierCancelsBeforeTransitionAndCommitsNothing() async throws {
        let uniqueId = "loadEarlier-\(UUID().uuidString)"
        let fixtureTs = "1899-01-01T00:00:00.000Z"
        defer { cleanupFixture(ts: fixtureTs) }
        DirectAPIConfig.mode = .ccServer

        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)
        vm.messages = [seedAnchorMessage(idSuffix: uniqueId)]

        stubHistoryResponse(ts: fixtureTs, uniqueId: uniqueId)

        // 掛起: entryMode(=ccServer) 在 loadEarlier() 入口就被冻结, 网络请求随后打进 HangingURLProtocol
        // 挂住不回应.
        let opTask = Task { await vm.loadEarlierTracked() }
        guard await HangingURLProtocol.waitForRequestReceived() else {
            XCTFail("fake transport 10s 内没收到请求 —— 被测函数大概率走了本地缓存分支提前返回, 没有真的发起网络请求")
            return
        }

        // 切模式: 走真实 DirectAPIConfig.mode setter → 真实 .ccDirectAPIModeChanged 通知 →
        // ChatViewModel 里注册的真实 handleModeChange() 观察者. 生产路径, 没有任何绕过.
        let startingGeneration = vm.modeGeneration
        DirectAPIConfig.mode = .directAPI
        await waitForTransitionToSettle(vm, after: startingGeneration)
        XCTAssertTrue(vm.messages.isEmpty, "mode 切换应该已经清空 UI messages(handleModeChange 的一部分)")

        // 放行: 挂起的响应现在才真正送达 loadEarlier() 内部的 await 点.
        await HangingURLProtocol.release()
        await opTask.value

        let fixtureText = fixtureText(uniqueId)
        let ccServerHasIt = recordExists(in: ChatStore.shared.snapshot(.ccServer), text: fixtureText)
        let directAPIHasIt = recordExists(in: ChatStore.shared.snapshot(.directAPI), text: fixtureText)

        XCTAssertFalse(ccServerHasIt, "tracked request 被 mode transition 取消后不应该提交旧响应")
        XCTAssertFalse(directAPIHasIt, "延迟到达的响应不应该落进切换后的 directAPI scope(串库)")

        let uiHasStaleRecord = vm.messages.contains { $0.text == fixtureText }
        XCTAssertFalse(uiHasStaleRecord, "延迟到达的 ccServer 响应不应该污染切换后 directAPI 模式的 UI messages")
    }

    func testRapidTripleLoadEarlierWaitsForTheOwnerChainAndStartsOnlyFinalReplacement() async {
        let uniqueId = "repeated-load-\(UUID().uuidString)"
        let fixtureTs = "1899-01-02T00:00:00.000Z"
        defer { cleanupFixture(ts: fixtureTs) }
        DirectAPIConfig.mode = .ccServer

        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)
        vm.messages = [seedAnchorMessage(idSuffix: uniqueId)]
        stubHistoryResponse(ts: fixtureTs, uniqueId: uniqueId)

        let first = Task { await vm.loadEarlierTracked() }
        guard await HangingURLProtocol.waitForRequestReceived(count: 1) else {
            XCTFail("first tracked request did not arrive")
            return
        }

        let second = Task { await vm.loadEarlierTracked() }
        await Task.yield()
        let third = Task { await vm.loadEarlierTracked() }
        let replacementArrived = await HangingURLProtocol.waitForRequestReceived(count: 2, timeout: 0.5)
        let orphanArrived = await HangingURLProtocol.waitForRequestReceived(count: 3, timeout: 0.2)
        await HangingURLProtocol.release()
        await first.value
        await second.value
        await third.value

        XCTAssertTrue(replacementArrived, "replacement request must start after the cancelled owner exits")
        XCTAssertFalse(orphanArrived, "superseded replacement must not overwrite the final owner and start as an orphan")
    }

    func testFastDoubleSwitchLeavesOneFinalBootstrapOwner() async {
        let uniqueId = "double-switch-\(UUID().uuidString)"
        let fixtureTs = "1899-01-03T00:00:00.000Z"
        defer { cleanupFixture(ts: fixtureTs) }
        DirectAPIConfig.mode = .ccServer

        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)
        vm.messages = [seedAnchorMessage(idSuffix: uniqueId)]
        stubHistoryResponse(ts: fixtureTs, uniqueId: uniqueId)

        let oldLoad = Task { await vm.loadEarlierTracked() }
        guard await HangingURLProtocol.waitForRequestReceived(count: 1) else {
            XCTFail("tracked request did not arrive")
            return
        }

        let startingGeneration = vm.modeGeneration
        DirectAPIConfig.mode = .directAPI
        DirectAPIConfig.mode = .ccServer

        await waitForTransitionToSettle(vm, after: startingGeneration)
        let finalBootstrapArrived = await HangingURLProtocol.waitForRequestReceived(count: 2, timeout: 1)
        let thirdRequestArrived = await HangingURLProtocol.waitForRequestReceived(count: 3, timeout: 0.2)
        let bootstrapRequests = HangingURLProtocol.capturedRequests.filter {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(URLQueryItem(name: "limit", value: "500")) == true
        }

        await HangingURLProtocol.release()
        await oldLoad.value
        vm.stop()

        XCTAssertTrue(finalBootstrapArrived, "final mode must launch its bootstrap owner")
        XCTAssertFalse(thirdRequestArrived, "coalesced transition must not launch a second final bootstrap")
        XCTAssertEqual(bootstrapRequests.count, 1, "only the final mode may own a bootstrap task")
        XCTAssertEqual(vm.modeGeneration, startingGeneration + 2)
        XCTAssertEqual(vm.settledModeGeneration, vm.modeGeneration)
    }

    func testRepeatedSearchKeepsOnlyReplacementResult() async {
        let fixtureTs = "1899-04-01T00:00:00.000Z"
        defer { cleanupFixture(ts: fixtureTs) }
        let firstQuery = "first-\(UUID().uuidString)"
        let secondQuery = "second-\(UUID().uuidString)"
        DirectAPIConfig.mode = .ccServer

        HangingURLProtocol.responseProvider = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? "missing"
            return HangingURLProtocol.StubResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: self.historyResponseJSON(ts: fixtureTs, text: "result-\(query)")
            )
        }
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession())
        vm.searchText = firstQuery
        let first = Task { await vm.searchServerTracked() }
        guard await HangingURLProtocol.waitForRequestReceived(count: 1) else {
            XCTFail("first search request did not arrive")
            return
        }

        vm.searchText = secondQuery
        let second = Task { await vm.searchServerTracked() }
        let replacementArrived = await HangingURLProtocol.waitForRequestReceived(count: 2, timeout: 0.5)
        await HangingURLProtocol.release()
        await first.value
        await second.value

        XCTAssertTrue(replacementArrived)
        XCTAssertEqual(vm.serverSearchResults.map(\.text), ["result-\(secondQuery)"])
    }

    func testRepeatedResyncReplacesBackfillOwnerDuringBootstrap() async {
        let seedTs = "1899-06-01T00:00:00.000Z"
        let seed = ChatMessage(
            ts: seedTs, role: "user", text: "resync-seed-\(UUID().uuidString)", source: nil,
            quotedTs: nil, quotedText: nil, attachmentUrl: nil, attachmentType: nil,
            attachmentFilename: nil, audioZh: nil, audioEn: nil, audioJa: nil,
            location: nil, metadata: nil, localId: nil
        )
        let previousBackfillFlag = UserDefaults.standard.object(forKey: "backfillComplete_v2")
        defer {
            cleanupFixture(ts: seedTs, role: "user")
            if let previousBackfillFlag {
                UserDefaults.standard.set(previousBackfillFlag, forKey: "backfillComplete_v2")
            } else {
                UserDefaults.standard.removeObject(forKey: "backfillComplete_v2")
            }
        }
        DirectAPIConfig.mode = .ccServer
        ChatStore.shared.snapshot(.ccServer).upsert([seed])
        HangingURLProtocol.responseProvider = { _ in
            HangingURLProtocol.StubResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"ok":true,"records":[]}"#.utf8)
            )
        }
        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)
        let pendingCount = vm.pendingFailedMessages.count

        await vm.start()
        guard await HangingURLProtocol.waitForRequestReceived(count: 1) else {
            XCTFail("bootstrap request did not arrive")
            return
        }

        NotificationCenter.default.post(name: NSNotification.Name("CcResyncHistory"), object: nil)
        let firstBackfillArrived = await HangingURLProtocol.waitForRequestReceived(count: 2, timeout: 0.3)
        NotificationCenter.default.post(name: NSNotification.Name("CcResyncHistory"), object: nil)
        let replacementBackfillArrived = await HangingURLProtocol.waitForRequestReceived(count: 3, timeout: 0.3)

        let startingGeneration = vm.modeGeneration
        DirectAPIConfig.mode = .directAPI
        await waitForTransitionToSettle(vm, after: startingGeneration)
        await HangingURLProtocol.release()
        vm.stop()

        let backfillRequests = HangingURLProtocol.capturedRequests.filter {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "before" }) == true
        }
        XCTAssertTrue(firstBackfillArrived)
        XCTAssertTrue(replacementBackfillArrived)
        XCTAssertEqual(backfillRequests.count, 2)
        XCTAssertNil(vm.backfillProgress)
        XCTAssertEqual(vm.pendingFailedMessages.count, pendingCount)
    }

    func testRepeatedJumpToDateKeepsOnlyReplacementTarget() async {
        let firstTs = "1800-01-01T00:00:00.000Z"
        let secondTs = "1800-01-02T00:00:00.000Z"
        defer {
            cleanupFixture(ts: firstTs)
            cleanupFixture(ts: secondTs)
        }
        DirectAPIConfig.mode = .ccServer

        HangingURLProtocol.responseProvider = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let day = components?.queryItems?.first(where: { $0.name == "date" })?.value
            let around = components?.queryItems?.first(where: { $0.name == "around_ts" })?.value
            let ts = around ?? (day == "1800-01-01" ? firstTs : secondTs)
            return HangingURLProtocol.StubResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: self.historyResponseJSON(ts: ts, text: "jump-\(ts)")
            )
        }
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession())
        let first = Task { await vm.jumpToDateTracked("1800-01-01") }
        guard await HangingURLProtocol.waitForRequestReceived(count: 1) else {
            XCTFail("first jump request did not arrive")
            return
        }

        let second = Task { await vm.jumpToDateTracked("1800-01-02") }
        let replacementArrived = await HangingURLProtocol.waitForRequestReceived(count: 2, timeout: 0.5)
        await HangingURLProtocol.release()
        await first.value
        await second.value

        XCTAssertTrue(replacementArrived)
        XCTAssertEqual(vm.jumpScrollTarget, secondTs + "assistant")
    }

    // 真机报告 2026-07-16: 直连模式聊完, 杀 app 重进, 聊天页空空.
    // 探针: directAPI 库里已有记录, fresh VM(模拟冷启动)在 directAPI 模式 start() 后记录必须回到 UI.
    func testDirectAPIColdStartLoadsCachedHistory() async {
        let ts = "1899-06-01T00:00:00.000Z"
        let marker = "cold-start-probe-\(UUID().uuidString)"
        defer { cleanupFixture(ts: ts, role: "user") }
        ChatStore.shared.snapshot(.directAPI).upsert([ChatMessage(
            ts: ts, role: "user", text: marker, source: "ios-app",
            quotedTs: nil, quotedText: nil, attachmentUrl: nil, attachmentType: nil,
            attachmentFilename: nil, audioZh: nil, audioEn: nil, audioJa: nil,
            location: nil, metadata: nil, localId: nil
        )])

        DirectAPIConfig.mode = .directAPI
        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)
        await vm.start()
        var i = 0
        while !vm.messages.contains(where: { $0.text == marker }) && i < 3000 {
            await Task.yield()
            i += 1
        }
        XCTAssertTrue(
            vm.messages.contains { $0.text == marker },
            "directAPI 冷启动没把本地缓存加载回 UI (loadCachedHistory 线断了)"
        )
        vm.stop()
    }

    // 真机 app-group domain 冷启动可能先回落 ccServer，随后在没有
    // ccDirectAPIModeChanged 通知的情况下变为 directAPI。初代启动若只拒绝旧 mode 的提交、
    // 却不补起新 mode transition，就会永久停在空页。这里直接写 suite 模拟同族时序。
    func testColdStartUnnotifiedModeDriftRestartsIntoDirectCache() async {
        let ts = "1899-06-02T00:00:00.000Z"
        let marker = "cold-start-drift-\(UUID().uuidString)"
        defer { cleanupFixture(ts: ts, role: "user") }
        ChatStore.shared.snapshot(.directAPI).upsert([ChatMessage(
            ts: ts, role: "user", text: marker, source: "ios-app",
            quotedTs: nil, quotedText: nil, attachmentUrl: nil, attachmentType: nil,
            attachmentFilename: nil, audioZh: nil, audioEn: nil, audioJa: nil,
            location: nil, metadata: nil, localId: nil
        )])

        let emptyHistory = (try? JSONSerialization.data(withJSONObject: [
            "ok": true,
            "records": [],
        ])) ?? Data()
        HangingURLProtocol.responseProvider = { _ in
            HangingURLProtocol.StubResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: emptyHistory
            )
        }

        DirectAPIConfig.mode = .ccServer
        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)
        defer { vm.stop() }
        await vm.start()
        guard await HangingURLProtocol.waitForRequestReceived() else {
            XCTFail("初代 ccServer bootstrap 请求未到达，无法建立受控 mode 漂移时序")
            return
        }

        // 绕过 DirectAPIConfig setter，刻意不发自定义 mode-change notification。
        UserDefaults(suiteName: CcServerConfig.appGroup)?.set(
            ChatBackendMode.directAPI.rawValue,
            forKey: "directapi.mode"
        )
        XCTAssertEqual(DirectAPIConfig.mode, .directAPI)
        let initialGeneration = vm.modeGeneration
        await HangingURLProtocol.release()
        await waitForTransitionToSettle(vm, after: initialGeneration)
        var i = 0
        while !vm.messages.contains(where: { $0.text == marker }) && i < 3000 {
            await Task.yield()
            i += 1
        }

        XCTAssertGreaterThan(vm.modeGeneration, initialGeneration)
        XCTAssertEqual(vm.settledModeGeneration, vm.modeGeneration)
        XCTAssertTrue(
            vm.messages.contains { $0.text == marker },
            "无通知 mode 漂移后没有补起 directAPI transition，本地历史仍不可见"
        )
    }

    func testDirectModeAppPathsCaptureNoServerRequests() async {
        DirectAPIConfig.mode = .directAPI
        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)

        await vm.start()
        await Task.yield()
        vm.messages = [seedAnchorMessage(idSuffix: UUID().uuidString)]
        await vm.loadEarlierTracked()
        vm.searchText = "zero-capture-\(UUID().uuidString)"
        await vm.searchServerTracked()
        let target = ChatMessage(
            ts: "1800-02-01T00:00:00.000Z", role: "assistant", text: "target", source: nil,
            quotedTs: nil, quotedText: nil, attachmentUrl: nil, attachmentType: nil,
            attachmentFilename: nil, audioZh: nil, audioEn: nil, audioJa: nil,
            location: nil, metadata: nil, localId: nil
        )
        await vm.jumpToMessageTracked(target)
        vm.stop()

        XCTAssertTrue(HangingURLProtocol.capturedRequests.isEmpty)
    }

    func testDirectToServerTransitionClearsModeScopedState() async {
        let markerTs = "1899-05-01T00:00:00.000Z"
        let markerText = "reverse-switch-\(UUID().uuidString)"
        defer { cleanupFixture(ts: markerTs) }
        DirectAPIConfig.mode = .directAPI
        let fakeClient = ChatNetworkClient(session: HangingURLProtocol.makeSession())
        let vm = ChatViewModel(session: HangingURLProtocol.makeSession(), networkClient: fakeClient)
        let marker = ChatMessage(
            ts: markerTs, role: "assistant", text: markerText, source: "direct-api",
            quotedTs: nil, quotedText: nil, attachmentUrl: nil, attachmentType: nil,
            attachmentFilename: nil, audioZh: nil, audioEn: nil, audioJa: nil,
            location: nil, metadata: nil, localId: nil
        )
        ChatStore.shared.snapshot(.directAPI).upsert([marker])
        vm.messages = [marker]
        vm.serverSearchResults = [marker]
        vm.jumpScrollTarget = marker.id
        vm.loadingEarlier = true
        vm.isServerSearching = true
        vm.sending = true
        vm.backfillProgress = .running(synced: 1)
        let pendingCount = vm.pendingFailedMessages.count
        let startingGeneration = vm.modeGeneration

        DirectAPIConfig.mode = .ccServer
        await waitForTransitionToSettle(vm, after: startingGeneration)
        vm.stop()

        XCTAssertFalse(vm.messages.contains { $0.text == markerText })
        XCTAssertTrue(vm.serverSearchResults.isEmpty)
        XCTAssertFalse(vm.loadingEarlier)
        XCTAssertFalse(vm.isServerSearching)
        XCTAssertFalse(vm.sending)
        XCTAssertNil(vm.backfillProgress)
        XCTAssertNil(vm.jumpScrollTarget)
        XCTAssertEqual(vm.pendingFailedMessages.count, pendingCount)
        XCTAssertTrue(recordExists(in: ChatStore.shared.snapshot(.directAPI), text: markerText))
        XCTAssertFalse(recordExists(in: ChatStore.shared.snapshot(.ccServer), text: markerText))
    }

    func testRepeatedDirectSendRemovesCancelledPlaceholderAndKeepsOneOwner() async {
        DirectAPIConfig.mode = .directAPI
        let harness = DirectStreamHarness()
        let vm = ChatViewModel(
            directAPIStream: { _, _, _, _, _, _ in harness.makeStream() },
            directAPIKeyProvider: { "integration-test-key" }
        )
        let prefix = "repeat-send-\(UUID().uuidString)"
        defer {
            let ids = Set(vm.messages.filter { $0.text.contains(prefix) || $0.source == "direct-api" }.map { $0.id })
            ChatStore.shared.snapshot(.directAPI).delete(ids: ids)
        }

        await vm.send(text: "\(prefix)-one")
        let firstStarted = await waitForStreamStarts(harness, count: 1)
        XCTAssertTrue(firstStarted)
        let second = Task { await vm.send(text: "\(prefix)-two") }
        let secondStarted = await waitForStreamStarts(harness, count: 2)
        XCTAssertTrue(secondStarted)
        harness.finishLatest(with: "stream-final")
        await second.value

        var i = 0
        while (vm.sending || !vm.messages.contains(where: { $0.text == "stream-final" })) && i < 3000 {
            await Task.yield()
            i += 1
        }
        let assistantMessages = vm.messages.filter { $0.source == "direct-api" }

        XCTAssertEqual(harness.activeCount, 0)
        XCTAssertEqual(assistantMessages.map { $0.text }, ["stream-final"])
        XCTAssertTrue(vm.pendingFailedMessages.isEmpty)
    }

    // MARK: - 负例: 证明测试本身有牙(上一轮 review 原話點名)

    /// fixed 半场: 跟正例测试同款冻结写法, 用共享 harness(fixedFetchAndStore) 复核一遍零串入 ——
    /// 这半场通过是下一条 buggy 测试有意义的前提(不然没法证明区分力来自 harness 而不是巧合).
    func testFixedScopeFreezing_doesNotCrossContaminate() async throws {
        let uniqueId = "fixed-\(UUID().uuidString)"
        let fixtureTs = "1899-02-01T00:00:00.000Z"
        defer { cleanupFixture(ts: fixtureTs) }
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
        DirectAPIConfig.mode = .ccServer
        stubHistoryResponse(ts: fixtureTs, uniqueId: uniqueId)
        let client = ChatNetworkClient(session: HangingURLProtocol.makeSession())

        let opTask = Task { try await fixedFetchAndStore(url: url, client: client) }
        guard await HangingURLProtocol.waitForRequestReceived() else {
            XCTFail("fake transport 10s 内没收到请求 —— 被测函数大概率走了本地缓存分支提前返回, 没有真的发起网络请求")
            return
        }
        DirectAPIConfig.mode = .directAPI
        await Task.yield()
        await HangingURLProtocol.release()
        try await opTask.value

        let fixtureText = fixtureText(uniqueId)
        XCTAssertTrue(recordExists(in: ChatStore.shared.snapshot(.ccServer), text: fixtureText),
                      "fixed 写法: 应落进发起请求时冻结的 ccServer scope")
        XCTAssertFalse(recordExists(in: ChatStore.shared.snapshot(.directAPI), text: fixtureText),
                       "fixed 写法: 不应该串进切换后的 directAPI scope")
    }

    /// buggy 半场: 故意让一个"会串库"的坏实现被这条测试抓红 —— 复刻
    /// learnings/2026-07-13_运行时computed路由跨await会串库 点名的原始 bug(网络等待期间用户切了
    /// 模式, 响应回来后重新读 ambient DirectAPIConfig.mode 才落库). 断言反过来要求"串库确实发生",
    /// 如果这两条断言失败, 说明 harness 本身测不出串库, 上一条 fixed 测试的 PASS 就不可信.
    func testAmbientModeRead_crossContaminates_provingTestHasTeeth() async throws {
        let uniqueId = "buggy-\(UUID().uuidString)"
        let fixtureTs = "1899-03-01T00:00:00.000Z"
        defer { cleanupFixture(ts: fixtureTs) }
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/history")
        DirectAPIConfig.mode = .ccServer
        stubHistoryResponse(ts: fixtureTs, uniqueId: uniqueId)
        let client = ChatNetworkClient(session: HangingURLProtocol.makeSession())

        let opTask = Task { try await buggyFetchAndStore(url: url, client: client) }
        guard await HangingURLProtocol.waitForRequestReceived() else {
            XCTFail("fake transport 10s 内没收到请求 —— 被测函数大概率走了本地缓存分支提前返回, 没有真的发起网络请求")
            return
        }
        DirectAPIConfig.mode = .directAPI
        await Task.yield()
        await HangingURLProtocol.release()
        try await opTask.value

        let fixtureText = fixtureText(uniqueId)
        let landedInCcServer = recordExists(in: ChatStore.shared.snapshot(.ccServer), text: fixtureText)
        let landedInDirectAPI = recordExists(in: ChatStore.shared.snapshot(.directAPI), text: fixtureText)

        XCTAssertFalse(landedInCcServer, "buggy 写法预期表现: ambient 读会让它漂到 directAPI scope, 不落 ccServer")
        XCTAssertTrue(landedInDirectAPI, "buggy 写法预期表现: ambient 读导致串库, 落进切换后的 directAPI scope(复现原始 bug)")
    }
}

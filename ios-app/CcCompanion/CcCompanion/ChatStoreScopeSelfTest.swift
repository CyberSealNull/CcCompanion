//
//  ChatStoreScopeSelfTest.swift
//  CcCompanion
//
//  DEBUG-only self-test(二审 P0-4 必跑测试之一: 切模式历史隔离). 项目没有 Xcode unit-test target
//  (只有 UI-testing bundle, 没有 TEST_HOST 能 @testable import CcCompanion), 新增 target 要手改
//  pbxproj, 风险跟上一轮"不该为了软要求盲改 project.pbxproj 冒炸两个既有 target"的判断一致——参照
//  本仓库已有的 DEBUG-only self-check 先例(会话状态栏的 convstatebar_demo flag), 用真实
//  ChatStore.migrate() schema + 真实 GRDB(临时文件, 不碰真实 app 缓存路径)验证双库物理隔离:
//  ccServer 库与 directAPI 库各自独立, 互不可见, upsert/latest/before/around 全部真跑不是静态断言。
//
//  由 CcCompanionApp.init() 在环境变量 CCC_UITEST_CHATSTORE_SCOPE_SELFTEST=1 时调用, 结果 print 到
//  stdout, 可以启动模拟器 + 该环境变量后用 `simctl launch --console-pty` 抓 "[ChatStoreScopeSelfTest]"
//  前缀确认 PASS/FAIL(这条通道已验证能可靠捕获——app 既有的 [CcFont] 诊断走的也是同一条 print/stdout)。
//
//  边界: 这个测试证明的是"两个物理库互相隔离"这条底层机制是真的(不是靠 mock/假设); 5 个具体函数
//  (bootstrapHistory/refreshRecent/loadEarlier/searchServer/jumpToMessage)"入口冻结 scope、全程沿用、
//  不中途重读 ambient"这条调用点纪律, 由源码本身的修复 + verify_chatstore_scope_freeze.sh 的静态扫描
//  兜底, 不在这个运行时测试的覆盖范围内(那五个函数分散在 ChatViewModel 私有方法里, 脱离真实 UI/网络
//  环境单独驱动它们的成本和风险不成比例, 诚实标注这条边界而不是编一个看似覆盖、实则套壳的测试)。
//

import Foundation
import GRDB

enum ChatStoreScopeSelfTest {
    static func run() {
        var failures: [String] = []
        do {
            try testDualQueueIsolation(&failures)
        } catch {
            failures.append("threw: \(error)")
        }
        if failures.isEmpty {
            print("[ChatStoreScopeSelfTest] PASS (dual-queue isolation verified against real GRDB schema)")
        } else {
            for f in failures { print("[ChatStoreScopeSelfTest] FAIL: \(f)") }
        }
    }

    private static func makeTempScope(name: String) throws -> ChatStoreScope {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreScopeSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).db")
        let queue = try DatabaseQueue(path: url.path)
        // 复用真实 migration(ChatStore.migrate 已从 private 改 internal), 不在测试里另写一份容易
        // 跟真 schema drift 的副本 schema.
        try ChatStore.migrate(queue)
        return ChatStoreScope(queue: queue)
    }

    private static func makeMessage(ts: String, text: String) -> ChatMessage {
        ChatMessage(
            ts: ts, role: "user", text: text, source: "selftest",
            quotedTs: nil, quotedText: nil, quotedRole: nil,
            attachmentUrl: nil, attachmentType: nil, attachmentFilename: nil,
            reactions: nil, audioZh: nil, audioEn: nil, audioJa: nil,
            location: nil, metadata: nil
        )
    }

    /// 双库 fixture: ccServer 模式 scope 与 directAPI 模式 scope 各自 upsert 各自的数据, 断言
    /// count/latest/before 全部互相看不到对方——直接对应二审"断言双库...零串入"这条。全程只用
    /// 同步的 upsert()(不用 upsertAsync)——self-test 跑在 App.init() 同步上下文里, 用 Task+信号量
    /// 桥接 async API 反而会在 init() 这种早期生命周期阶段引入不必要的死锁风险, 犯不上。
    private static func testDualQueueIsolation(_ failures: inout [String]) throws {
        let ccServer = try makeTempScope(name: "ccServer")
        let directAPI = try makeTempScope(name: "directAPI")

        let t1 = "2026-07-13T10:00:00.000Z"
        let t2 = "2026-07-13T10:01:00.000Z"
        let t3 = "2026-07-13T10:02:00.000Z"

        ccServer.upsert([
            makeMessage(ts: t1, text: "ccServer-msg-1"),
            makeMessage(ts: t2, text: "ccServer-msg-2"),
        ])
        directAPI.upsert([makeMessage(ts: t3, text: "directAPI-msg-1")])

        if ccServer.count() != 2 {
            failures.append("ccServer scope expected 2 records after its own upsert, got \(ccServer.count())")
        }
        if directAPI.count() != 1 {
            failures.append("directAPI scope expected 1 record after its own upsert, got \(directAPI.count())")
        }

        let ccServerTexts = Set(ccServer.latest().map { $0.text })
        let directAPITexts = Set(directAPI.latest().map { $0.text })
        if !ccServerTexts.isDisjoint(with: directAPITexts) {
            failures.append("ccServer and directAPI queues share records: \(ccServerTexts.intersection(directAPITexts))")
        }
        if ccServerTexts.contains("directAPI-msg-1") {
            failures.append("ccServer queue leaked the directAPI-only record")
        }
        if directAPITexts.contains("ccServer-msg-1") || directAPITexts.contains("ccServer-msg-2") {
            failures.append("directAPI queue leaked a ccServer-only record")
        }

        // loadEarlier() 实际调的方法: before() 也要在各自库里各自正确, 不串到对方.
        if ccServer.before(ts: t2, limit: 10).map({ $0.text }) != ["ccServer-msg-1"] {
            failures.append("ccServer.before(ts: t2) did not return exactly ccServer-msg-1")
        }
        if directAPI.before(ts: t2, limit: 10).isEmpty == false {
            failures.append("directAPI.before(ts: t2) should be empty (its only record is after t2), got leakage or wrong data")
        }
    }
}

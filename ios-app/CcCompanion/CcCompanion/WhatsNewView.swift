//
//  WhatsNewView.swift
//  CcCompanion
//
//  v1.2 — 新 build 首启弹「这一版改了什么」。
//  内容源走公开 GitHub 仓库 raw CHANGELOG.json 当公告板 (外部用户连自家 server, server 下发够不着;
//  GitHub raw 全网可拉, 改文件即改文案)。拉不到 (超时/离线) 回退内置当版文案保底。
//  对外口径: 只称 Claude, 不露任何内部代号 (AI 透明红线)。
//

import SwiftUI

struct WhatsNewEntry: Codable, Equatable {
    let title: String
    let items: [String]
    var footer: String? = nil
}

enum WhatsNewSource {
    /// 公开 repo raw 公告板: 改这个文件即改全网用户看到的文案 (不用发新 build)。
    static let changelogURLString = "https://raw.githubusercontent.com/CyberSealNull/CcCompanion/main/CHANGELOG.json"
    static let lastSeenKey = "cc.whatsnew.lastSeenBuild"

    static var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
    }

    /// 内置回退当版文案 (GitHub 拉不到时保底)。只称 Claude。build 号为 key。
    /// 注: 230 = 当前 staging 测试版自检用; 231 = External 首发正式文案。
    static let fallback: [String: WhatsNewEntry] = [
        "230": WhatsNewEntry(
            title: "测试版更新",
            items: [
                "这是一个内部测试版本，用于验证「微信主题」与更新提示等新功能。",
                "如遇连接问题，请确认 Tailscale 已开启并连上你的服务器。",
            ],
            footer: "由 Claude 提供支持"
        ),
        "231": WhatsNewEntry(
            title: "这一版更新了什么",
            items: [
                "修复了部分网络环境下 Tailscale 连接会中断的问题，连接更稳定了。",
                "如果你还在更早的版本，建议通过 TestFlight 更新到最新版获得最佳体验。",
            ],
            footer: "由 Claude 提供支持"
        ),
    ]

    /// 先拉 GitHub raw (超时 6s), 失败或无当 build 条目则回退内置。
    static func fetchEntry(forBuild build: String) async -> WhatsNewEntry? {
        if let url = URL(string: changelogURLString) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false,
               let map = try? JSONDecoder().decode([String: WhatsNewEntry].self, from: data),
               let remote = map[build] {
                return remote
            }
        }
        return fallback[build]   // 离线/超时/无条目 → 内置保底
    }
}

// MARK: - 弹窗 UI (跟 ccc 现有风格走, 不过度设计)

struct WhatsNewSheet: View {
    let entry: WhatsNewEntry
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.ccAccent)
                Text(entry.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.ccText)
                Spacer()
            }
            .padding(.top, 28).padding(.horizontal, 24).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Color.ccAccent).frame(width: 6, height: 6).padding(.top, 7)
                            Text(item)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.ccText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            if let footer = entry.footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccTextDim)
                    .padding(.horizontal, 24).padding(.top, 14)
            }

            Button(action: onClose) {
                Text("知道了")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.ccAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 28)
        }
        .background(Color.ccBg.ignoresSafeArea())
    }
}

// MARK: - 启动 gate (挂 ContentView 上, 新 build 首启弹一次, 看完记录不再弹)

struct WhatsNewGate: ViewModifier {
    @State private var entry: WhatsNewEntry? = nil
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .task { await checkOnce() }
            .sheet(isPresented: $presented) {
                if let entry {
                    WhatsNewSheet(entry: entry, onClose: markSeenAndDismiss)
                        .presentationDetents([.medium, .large])
                }
            }
    }

    private func checkOnce() async {
        let build = WhatsNewSource.currentBuild
        guard !build.isEmpty else { return }
        // 已看过当前 build → 不弹
        if UserDefaults.standard.string(forKey: WhatsNewSource.lastSeenKey) == build { return }
        if let e = await WhatsNewSource.fetchEntry(forBuild: build) {
            await MainActor.run { entry = e; presented = true }
        }
        // 当 build 没有文案 → 不弹也不标 lastSeen (将来 GitHub 加上该 build 条目再弹)。
    }

    private func markSeenAndDismiss() {
        UserDefaults.standard.set(WhatsNewSource.currentBuild, forKey: WhatsNewSource.lastSeenKey)
        presented = false
    }
}

extension View {
    /// 新 build 首启弹 What's New。挂在根 view 上。
    func whatsNewGate() -> some View { modifier(WhatsNewGate()) }
}

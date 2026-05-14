//
//  FavoritedTurnsCache.swift
//  OpiaCompanion
//
//  Phase 设置大砍 (item B) — 本地缓存哪些 turn-end ts 已被收藏.
//  启动时拉 /favorites 一次填充, add/remove 双写 server + local Set, ChatBubble 观察显示 fill icon.
//

import SwiftUI
import Combine

@MainActor
final class FavoritedTurnsCache: ObservableObject {
    static let shared = FavoritedTurnsCache()
    @Published private(set) var turnEnds: Set<String> = []

    private init() {}

    func contains(_ ts: String) -> Bool {
        turnEnds.contains(ts)
    }

    func insert(_ ts: String) {
        turnEnds.insert(ts)
    }

    func remove(_ ts: String) {
        turnEnds.remove(ts)
    }

    /// One-shot load from server `/favorites/list?limit=10000` (push.py only exposes /favorites/list,
    /// not bare /favorites). Walks records + collects each entry's last ref ts (turn end ts).
    /// Run from ChatViewModel.start() once.
    func refreshFromServer() async {
        var comps = URLComponents(url: OpiaServerConfig.serverURL.appendingPathComponent("favorites/list"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "limit", value: "10000")]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        if let secret = OpiaServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let records = json["records"] as? [[String: Any]] else { return }
            var collected: Set<String> = []
            for record in records {
                if let refs = record["refs"] as? [[String: Any]],
                   let lastTs = refs.last?["ts"] as? String {
                    collected.insert(lastTs)
                }
            }
            self.turnEnds = collected
        } catch {
            // ignore — keep current cache
        }
    }
}

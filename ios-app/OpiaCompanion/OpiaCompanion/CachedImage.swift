//
//  CachedImage.swift
//  OpiaCompanion
//
//  替代 AsyncImage — 用 NSCache 缓存 + 共享 URLSession (HTTP cache)
//  解决 chat list scroll 上下时 image bubble 反复重新加载
//

import SwiftUI
import Foundation

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 200       // 最多缓存 200 张
        c.totalCostLimit = 80 * 1024 * 1024  // 80 MB
        return c
    }()

    func get(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ url: URL, image: UIImage) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

struct CachedImage<Placeholder: View, Content: View>: View {
    let url: URL
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loaded: UIImage?
    @State private var failed: Bool = false

    init(
        url: URL,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        // view init 时同步从 cache 读 — 避免 List cell reuse 时 placeholder flicker
        if let cached = ImageCache.shared.get(url) {
            self._loaded = State(wrappedValue: cached)
        }
    }

    var body: some View {
        Group {
            if let img = loaded {
                content(Image(uiImage: img))
            } else if failed {
                placeholder()
            } else {
                placeholder()
                    .task { await load() }
            }
        }
    }

    private func load() async {
        if let cached = ImageCache.shared.get(url) {
            self.loaded = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                ImageCache.shared.set(url, image: img)
                self.loaded = img
            } else {
                self.failed = true
            }
        } catch {
            self.failed = true
        }
    }
}

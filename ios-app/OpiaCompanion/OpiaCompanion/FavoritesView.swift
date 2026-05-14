//
//  FavoritesView.swift
//  OpiaCompanion
//
//  Favorites browser for server-side favorites.jsonl.
//
//  Phase E (item 3) 2026-05-11 — cccompanion 也要能开收藏页.
//

import SwiftUI
import Foundation
import Combine
#if canImport(Photos)
import Photos
#endif

nonisolated struct FavoriteItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let createdAt: String
    let type: String
    let source: String
    let refs: [FavoriteRef]
    let tags: [String]?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, type, source, refs, tags, note
        case createdAt = "created_at"
    }
}

nonisolated struct FavoriteRef: Codable, Hashable, Sendable {
    let ts: String?
    let role: String?
    let text: String?
    let attachmentUrl: String?
    let url: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case ts, role, text, url, title
        case attachmentUrl = "attachment_url"
    }
}

nonisolated struct FavoritesListResponse: Codable, Sendable {
    let ok: Bool?
    let records: [FavoriteItem]
    let count: Int?
}

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published var items: [FavoriteItem] = []
    @Published var filterType: FilterType = .all
    @Published var searchText = ""
    @Published var loading = false
    @Published var error: String?

    enum FilterType: String, CaseIterable, Identifiable {
        // Phase favorites polish 2026-05-11 (item 1) — 砍 .collection (合集 tab), 留 4 项
        case all = "全部"
        case text = "文字"
        case image = "图片"
        case link = "链接"
        var id: String { rawValue }

        var queryValue: String? {
            switch self {
            case .all: return nil
            case .text: return "text"
            case .image: return "image"
            case .link: return "link"
            }
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            var comp = URLComponents(url: OpiaServerConfig.serverURL.appendingPathComponent("favorites/list"), resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "limit", value: "80"),
                URLQueryItem(name: "offset", value: "0")
            ]
            if let type = filterType.queryValue { query.append(URLQueryItem(name: "type", value: type)) }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { query.append(URLQueryItem(name: "q", value: q)) }
            comp.queryItems = query
            let (data, _) = try await URLSession.shared.data(from: comp.url!)
            let decoded = try await Task.detached {
                try JSONDecoder().decode(FavoritesListResponse.self, from: data)
            }.value
            items = decoded.records
            error = nil
        } catch {
            self.error = "加载收藏失败: \(error.localizedDescription)"
        }
    }

    func delete(id: String) async {
        do {
            let url = OpiaServerConfig.serverURL.appendingPathComponent("favorites/delete")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let secret = OpiaServerConfig.sharedSecret, !secret.isEmpty {
                req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: ["id": id])
            _ = try await URLSession.shared.data(for: req)
            items.removeAll { $0.id == id }
        } catch {
            self.error = "删除失败: \(error.localizedDescription)"
        }
    }
}

struct FavoritesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = FavoritesViewModel()
    @State private var selected: FavoriteItem?
    // Phase favorites detail polish 2026-05-11 — 撤回上轮 image short-circuit, 所有 item 都走 detail.
    // FullImagePreview 路由搬到 FavoriteDetailView 自己管 @State.

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.opiaSerifAdaptive(size: 17, weight: .semibold))
                        .foregroundStyle(Color.opiaText)
                }
                Spacer()
                Text("收藏夹")
                    .font(.opiaSerifAdaptive(size: 17, weight: .semibold))
                    .foregroundStyle(Color.opiaText)
                Spacer()
                // placeholder 撑对称
                Image(systemName: "xmark")
                    .font(.opiaSerifAdaptive(size: 17, weight: .semibold))
                    .opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.opiaBg)

            Picker("类型", selection: $vm.filterType) {
                ForEach(FavoritesViewModel.FilterType.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List {
                if vm.loading && vm.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                ForEach(vm.items) { item in
                    FavoriteRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = item }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await vm.delete(id: item.id) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
                if let err = vm.error {
                    Text(err)
                        .font(.opiaSerifAdaptive(size: 12))
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color.opiaBg)
        .toolbar(.hidden, for: .navigationBar)
        .searchable(text: $vm.searchText, prompt: "搜收藏")
        .onSubmit(of: .search) { Task { await vm.load() } }
        .onChange(of: vm.filterType) { _, _ in Task { await vm.load() } }
        .onChange(of: vm.searchText) { _, value in
            if value.isEmpty { Task { await vm.load() } }
        }
        .sheet(item: $selected) { item in
            NavigationStack { FavoriteDetailView(item: item) }
        }
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }
}

// 收集 item.refs 里所有 image attachment URL (item-level helper, FavoriteDetailView 复用).
func favoriteImageURLs(for item: FavoriteItem) -> [URL] {
    item.refs.compactMap { ref -> URL? in
        guard let path = ref.attachmentUrl, !path.isEmpty else { return nil }
        let lower = path.lowercased()
        let isImg = lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") || lower.hasSuffix(".heic")
        guard item.type == "image" || isImg else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        let prefix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: OpiaServerConfig.serverURL.absoluteString + prefix)
    }
}

/// 单 ref 的 image URL (用 ref.attachmentUrl 直接拼 server prefix). 给 FavoriteDetailView image cell 用.
func favoriteImageURL(for ref: FavoriteRef) -> URL? {
    guard let path = ref.attachmentUrl, !path.isEmpty else { return nil }
    if path.hasPrefix("http") { return URL(string: path) }
    let prefix = path.hasPrefix("/") ? path : "/" + path
    return URL(string: OpiaServerConfig.serverURL.absoluteString + prefix)
}

/// 判 ref 是否 image (按后缀, item.type=image 时也算).
func favoriteRefIsImage(_ ref: FavoriteRef, itemType: String) -> Bool {
    guard let path = ref.attachmentUrl?.lowercased(), !path.isEmpty else { return false }
    if itemType == "image" { return true }
    return path.hasSuffix(".png") || path.hasSuffix(".jpg") || path.hasSuffix(".jpeg")
        || path.hasSuffix(".gif") || path.hasSuffix(".webp") || path.hasSuffix(".heic")
}

// MARK: - Image preview payload

struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let startIndex: Int
}

struct FavoriteRow: View {
    let item: FavoriteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 2026-05-09 用户 push 不显示 item.id 那串 hash 当标题
            // 改成日期 + 类型图标 真内容靠 contentPreview
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color.opiaAccent)
                Spacer()
                Text(shortDate(item.createdAt))
                    .font(.opiaSerifAdaptive(size: 11))
                    .foregroundStyle(Color.opiaTextDim)
            }

            contentPreview

            if let tags = item.tags, !tags.isEmpty {
                HStack {
                    ForEach(tags.prefix(4), id: \.self) { tag in
                        Text(tag)
                            .font(.opiaSerifAdaptive(size: 11))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.opiaAssistant.opacity(0.8))
                            .clipShape(Capsule())
                    }
                }
            }
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(.opiaSerifAdaptive(size: 12))
                    .foregroundStyle(Color.opiaTextDim)
            }
        }
        .padding(12)
        .background(Color.opiaCard.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.type {
        case "image":
            if let url = firstAttachmentURL() {
                CachedImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color.opiaCard)
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(firstText)
                .font(.opiaSerifAdaptive(size: 16))
                .foregroundStyle(Color.opiaText)
                .lineLimit(2)
        case "link":
            if let ref = item.refs.first {
                Label(ref.title ?? ref.url ?? firstText, systemImage: "link")
                    .font(.opiaSerifAdaptive(size: 16, weight: .medium))
                    .foregroundStyle(Color.opiaText)
                    .lineLimit(2)
            }
        case "collection":
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(item.refs.prefix(3).enumerated()), id: \.offset) { _, ref in
                    Text(ref.text ?? "")
                        .font(.opiaSerifAdaptive(size: 16))
                        .foregroundStyle(Color.opiaText)
                        .lineLimit(2)
                }
            }
        default:
            Text(firstText)
                .font(.opiaSerifAdaptive(size: 16))
                .foregroundStyle(Color.opiaText)
                .lineLimit(4)
        }
    }

    private var icon: String {
        switch item.type {
        case "image": return "photo"
        case "link": return "link"
        case "collection": return "square.stack.3d.up"
        default: return "text.quote"
        }
    }

    private var firstText: String {
        item.refs.compactMap(\.text).first(where: { !$0.isEmpty }) ?? ""
    }

    private func firstAttachmentURL() -> URL? {
        guard let path = item.refs.compactMap(\.attachmentUrl).first else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: OpiaServerConfig.serverURL.absoluteString + (path.hasPrefix("/") ? path : "/" + path))
    }

    private func shortDate(_ raw: String) -> String {
        String(raw.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

struct FavoriteDetailView: View {
    let item: FavoriteItem
    @Environment(\.dismiss) private var dismiss
    // Phase favorites detail polish 2026-05-11 — image cell tap → 全屏 preview, 多图共享一个 paged preview
    @State private var imagePreview: ImagePreviewPayload? = nil

    private var allImageURLs: [URL] { favoriteImageURLs(for: item) }

    var body: some View {
        List {
            Section {
                ForEach(Array(item.refs.enumerated()), id: \.offset) { _, ref in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(resolvedFavoriteRole(ref.role))
                                .font(.opiaSerifAdaptive(size: 12, weight: .semibold))
                                .foregroundStyle(Color.opiaAccent)
                            Spacer()
                            Text(ref.ts ?? "")
                                .font(.opiaSerifAdaptive(size: 11))
                                .foregroundStyle(Color.opiaTextDim)
                        }
                        if let text = ref.text, !text.isEmpty {
                            Text(text)
                                .foregroundStyle(Color.opiaText)
                                .textSelection(.enabled)
                        }
                        // Image attachment cell — 缩略图 + tap 弹 FullImagePreview (起始 index = 该 ref 在 allImageURLs 里的位置)
                        if favoriteRefIsImage(ref, itemType: item.type),
                           let url = favoriteImageURL(for: ref) {
                            CachedImage(url: url) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(Color.opiaCard)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let idx = allImageURLs.firstIndex(of: url) ?? 0
                                imagePreview = ImagePreviewPayload(urls: allImageURLs, startIndex: idx)
                            }
                        }
                        if let url = ref.url, !url.isEmpty {
                            Link(ref.title ?? url, destination: URL(string: url)!)
                        }
                    }
                    .listRowBackground(Color.opiaCard.opacity(0.7))
                }
            }
            if let note = item.note, !note.isEmpty {
                Section("note") {
                    Text(note)
                        .foregroundStyle(Color.opiaText)
                        .listRowBackground(Color.opiaCard.opacity(0.7))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.opiaBg)
        .navigationTitle(item.id)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .fullScreenCover(item: $imagePreview) { payload in
            FullImagePreview(urls: payload.urls, startIndex: payload.startIndex)
        }
    }
}

private func resolvedFavoriteRole(_ raw: String?) -> String {
    let value = (raw ?? "ref").lowercased()
    if value == "user" || value == "mian" || value == "用户" || value == "bonnie" {
        return OpiaNameResolver.name(for: .user)
    }
    if value == "assistant" || value == "opia" || value == "claude" {
        return OpiaNameResolver.name(for: .ai)
    }
    return raw ?? "ref"
}


// MARK: - Full image preview (Phase favorites polish 2026-05-11 item 2/3)

struct FullImagePreview: View {
    let urls: [URL]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var toast: String = ""
    @State private var saving: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 多图 paging, 单图也走 TabView (PageStyle 会自动隐 indicator if count==1 不漂亮 — 简化: 单图直接 Image)
            if urls.count == 1, let url = urls.first {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView().tint(.white)
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure:
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                            Text("图片加载失败")
                        }
                        .foregroundStyle(.white)
                    @unknown default: EmptyView()
                    }
                }
                .padding(20)
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty: ProgressView().tint(.white)
                            case .success(let image): image.resizable().scaledToFit()
                            case .failure:
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 40))
                                    Text("图片加载失败")
                                }
                                .foregroundStyle(.white)
                            @unknown default: EmptyView()
                            }
                        }
                        .tag(idx)
                        .padding(20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }

            // 顶部 / 底部 控件
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Text("完成")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    if urls.count > 1 {
                        Text("\(currentIndex + 1) / \(urls.count)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                Spacer()
                if !toast.isEmpty {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.7))
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
                Button {
                    Task { await saveCurrent() }
                } label: {
                    HStack(spacing: 6) {
                        if saving {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(saving ? "保存中..." : "保存到相册")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.opiaAccent)
                    .clipShape(Capsule())
                }
                .disabled(saving)
                .padding(.bottom, 36)
            }
        }
        .onAppear {
            currentIndex = max(0, min(startIndex, urls.count - 1))
        }
    }

    @MainActor
    private func saveCurrent() async {
        guard urls.indices.contains(currentIndex) else { return }
        let url = urls[currentIndex]
        saving = true
        defer { saving = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            #if canImport(Photos) && os(iOS)
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            }
            showToast("已保存到相册")
            #else
            showToast("当前平台不支持保存到相册")
            #endif
        } catch {
            showToast("保存失败: \(error.localizedDescription)")
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = "" }
        }
    }
}

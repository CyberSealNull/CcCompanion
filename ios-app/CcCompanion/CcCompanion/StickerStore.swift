import SwiftUI
import PhotosUI
import Combine

// 微信主题 v2.7 B: 表情包.
// 预加载 GET /stickers/list 缓存 id→(url,desc); 面板 grid + 上传; 气泡按 sticker_id 找 url 用 CachedImage 渲染成图.
// 表情包是通用素材走 server 远程拉, 两 flavor 都用, iOS 不 bundle 任何表情包资源.

struct StickerItem: Codable, Identifiable, Hashable {
    let id: String
    let filename: String?
    let desc: String?
    let url: String   // 形如 /attachments/sticker_xxx.jpg

    func fullURL() -> URL? {
        if url.hasPrefix("http") { return URL(string: url) }
        let path = url.hasPrefix("/") ? String(url.dropFirst()) : url
        return CcServerConfig.serverURL.appendingPathComponent(path)
    }
}

private struct StickerListResponse: Codable {
    let ok: Bool?
    let stickers: [StickerItem]?
}

private struct StickerUploadResponse: Codable {
    let ok: Bool?
    let sticker: StickerItem?
}

@MainActor
final class StickerStore: ObservableObject {
    static let shared = StickerStore()

    @Published private(set) var stickers: [StickerItem] = []
    @Published private(set) var loading = false

    private var lastLoaded: Date?

    func item(for id: String) -> StickerItem? {
        stickers.first { $0.id == id }
    }

    /// 预加载/刷新. 进微信主题 / app 启动调. 5 分钟内有缓存且非强制不重复拉.
    func preload(force: Bool = false) {
        if loading { return }
        if !force, let last = lastLoaded, Date().timeIntervalSince(last) < 300, !stickers.isEmpty { return }
        Task { await load() }
    }

    func load() async {
        loading = true
        defer { loading = false }
        let url = CcServerConfig.serverURL.appendingPathComponent("stickers/list")
        if let (data, _) = try? await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url)),
           let resp = try? JSONDecoder().decode(StickerListResponse.self, from: data),
           let list = resp.stickers {
            self.stickers = list
            self.lastLoaded = Date()
        }
        // 失败保留旧数据, 不崩.
    }

    /// 发表情包: POST /chat/send {sticker_id}. 静默 fire-and-forget, server append 后 poll 自然带回渲染.
    func send(stickerId: String) async {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sticker_id": stickerId, "text": ""])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 上传: POST /stickers/upload?desc=&filename= body=raw 图片字节. 成功刷新列表.
    func upload(imageData: Data, desc: String, filename: String) async -> Bool {
        var comps = URLComponents(url: CcServerConfig.serverURL.appendingPathComponent("stickers/upload"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "desc", value: desc),
            URLQueryItem(name: "filename", value: filename)
        ]
        guard let url = comps?.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        req.timeoutInterval = 30
        req.httpBody = imageData
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let resp = try? JSONDecoder().decode(StickerUploadResponse.self, from: data), resp.ok == true {
            await load()
            return true
        }
        return false
    }
}

// MARK: - 面板 sheet (所有主题可用, 自包含 send/upload)

struct StickerPickerSheet: View {
    @ObservedObject private var store = StickerStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingUploadData: Data?
    @State private var uploadDesc: String = ""
    @State private var uploading = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.stickers) { item in
                        Button {
                            Task { await store.send(stickerId: item.id) }
                            dismiss()
                        } label: {
                            stickerThumb(item)
                        }
                        .buttonStyle(.plain)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .frame(width: 76, height: 76)
                            .overlay(Image(systemName: "plus").font(.system(size: 26)).foregroundStyle(.gray))
                    }
                }
                .padding(16)
            }
            .navigationTitle("表情包")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .overlay {
                if store.stickers.isEmpty && store.loading {
                    ProgressView()
                }
            }
            .sheet(isPresented: Binding(get: { pendingUploadData != nil }, set: { if !$0 { pendingUploadData = nil } })) {
                uploadSheet
            }
        }
        .onAppear { store.preload() }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    pendingUploadData = data
                    uploadDesc = ""
                }
                pickerItem = nil
            }
        }
    }

    @ViewBuilder
    private func stickerThumb(_ item: StickerItem) -> some View {
        if let url = item.fullURL() {
            CachedImage(url: url) { img in
                img.resizable().scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } placeholder: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 76, height: 76)
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 76, height: 76)
        }
    }

    private var uploadSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let data = pendingUploadData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                TextField("给表情包写个语义描述 (AI 靠它选用)", text: $uploadDesc)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding(16)
            .navigationTitle("上传表情包")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pendingUploadData = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(uploading ? "上传中…" : "上传") {
                        guard let data = pendingUploadData else { return }
                        uploading = true
                        Task {
                            let fname = "sticker_\(Int(Date().timeIntervalSince1970)).jpg"
                            _ = await store.upload(imageData: data, desc: uploadDesc, filename: fname)
                            uploading = false
                            pendingUploadData = nil
                        }
                    }
                    .disabled(uploading || uploadDesc.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 气泡内表情包渲染 (所有主题复用; 找到 url 渲染成图, 找不到降级 desc/[表情] 文本不崩)

struct StickerBubbleContent: View {
    let stickerId: String
    let fallbackText: String?
    @ObservedObject private var store = StickerStore.shared

    var body: some View {
        Group {
            if let item = store.item(for: stickerId), let url = item.fullURL() {
                CachedImage(url: url) { img in
                    img.resizable().scaledToFit()
                        .frame(maxWidth: 130, maxHeight: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 100, height: 100)
                }
            } else {
                // 降级: 无缓存 / 不在列表 / 非微信也走这里, 别崩.
                Text(degradeText)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .onAppear { store.preload() }
    }

    private var degradeText: String {
        if let item = store.item(for: stickerId), let d = item.desc, !d.isEmpty { return "[表情] \(d)" }
        if let t = fallbackText, !t.isEmpty { return t }
        return "[表情]"
    }
}

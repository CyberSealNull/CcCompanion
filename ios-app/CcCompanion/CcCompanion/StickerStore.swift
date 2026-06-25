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

enum StickerSendError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器响应无效"
        case .server(let message):
            return message
        }
    }
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

    /// 发表情包: POST /chat/send {sticker_id}. 成功后 poll 自然带回渲染; 失败由 sheet 留住并提示.
    func send(stickerId: String) async throws {
        let url = CcServerConfig.serverURL.appendingPathComponent("chat/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sticker_id": stickerId, "text": ""])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw StickerSendError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = obj["error"] as? String, !message.isEmpty {
                throw StickerSendError.server(message)
            }
            throw StickerSendError.server("HTTP \(http.statusCode)")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = obj["ok"] as? Bool, ok == false {
            throw StickerSendError.server((obj["error"] as? String) ?? "发送失败")
        }
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

    /// 删除表情包: POST /stickers/delete {sticker_id}. 成功后刷新列表 (server 移除 store + 删图, 本地 reload 不再现).
    func delete(stickerId: String) async -> Bool {
        let url = CcServerConfig.serverURL.appendingPathComponent("stickers/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = CcServerConfig.sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sticker_id": stickerId])
        if let (_, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
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
    @State private var sendingStickerId: String?
    @State private var sendError: String?
    @State private var uploadError: String?
    // v2.8: 长按表情包删除 (确认后调 store.delete).
    @State private var stickerToDelete: StickerItem?
    @State private var deleting = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.stickers) { item in
                        Button {
                            guard sendingStickerId == nil else { return }
                            sendingStickerId = item.id
                            Task {
                                do {
                                    try await store.send(stickerId: item.id)
                                    sendingStickerId = nil
                                    dismiss()
                                } catch {
                                    sendingStickerId = nil
                                    sendError = error.localizedDescription
                                    CcToastBus.shared.show("表情发送失败")
                                }
                            }
                        } label: {
                            ZStack {
                                stickerThumb(item)
                                if sendingStickerId == item.id {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.black.opacity(0.18))
                                        .frame(width: 76, height: 76)
                                    ProgressView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(sendingStickerId != nil)
                        .contextMenu {
                            Button(role: .destructive) {
                                stickerToDelete = item
                            } label: {
                                Label("删除表情", systemImage: "trash")
                            }
                        }
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
            .alert("发送失败", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
                Button("好", role: .cancel) { sendError = nil }
            } message: {
                Text(sendError ?? "")
            }
            .alert("上传失败", isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })) {
                Button("好", role: .cancel) { uploadError = nil }
            } message: {
                Text(uploadError ?? "")
            }
            .confirmationDialog("删除这个表情包?", isPresented: Binding(get: { stickerToDelete != nil }, set: { if !$0 { stickerToDelete = nil } }), presenting: stickerToDelete) { item in
                Button("删除", role: .destructive) {
                    deleting = true
                    Task {
                        let ok = await store.delete(stickerId: item.id)
                        deleting = false
                        stickerToDelete = nil
                        if !ok { CcToastBus.shared.show("删除失败") }
                    }
                }
                Button("取消", role: .cancel) { stickerToDelete = nil }
            } message: { item in
                Text((item.desc?.isEmpty == false ? item.desc! + " · " : "") + "删除后不可恢复")
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
                            let ok = await store.upload(imageData: data, desc: uploadDesc, filename: fname)
                            uploading = false
                            if ok {
                                pendingUploadData = nil
                            } else {
                                uploadError = "请检查网络或服务器表情包上传接口。"
                                CcToastBus.shared.show("表情上传失败")
                            }
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

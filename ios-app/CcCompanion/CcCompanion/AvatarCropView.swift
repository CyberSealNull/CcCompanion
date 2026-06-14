//
//  AvatarCropView.swift
//  CcCompanion
//
//  Phase C — circular crop UI for avatar selection.
//  Spec: cccompanion_wizard_polish_phase_c_20260511.md
//  Used by WizardStepAIIdentity + WizardStepUserIdentity (and future settings page).
//

import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    static let ccIdentityDidChange = Notification.Name("CcIdentityDidChange")
}

enum CcIdentityRole {
    case ai
    case user
}

enum CcNameResolver {
    static func name(for role: CcIdentityRole) -> String {
        switch role {
        case .ai:
            return UserDefaults.standard.string(forKey: "ai_name") ?? CcDefaultAIName
        case .user:
            return UserDefaults.standard.string(forKey: "user_name") ?? CcDefaultUserName
        }
    }

    static func name(forMessageRole role: String) -> String {
        switch role {
        case "user": return name(for: .user)
        case "assistant": return name(for: .ai)
        case "task": return "· 任务"
        default: return role
        }
    }

    static func notifyChanged() {
        NotificationCenter.default.post(name: .ccIdentityDidChange, object: nil)
    }
}

struct CcAvatarView: View {
    let role: CcIdentityRole
    let size: CGFloat

    // v2.3 BUG 修: observe ThemeStore, 否则运行时切到 .wechat 时本 view 不重算 clipShape (配合下面 .id 钉死身份), 头像卡在首次算的 Circle 不变方. 同 6483669 字体串主题 bug 一族 (静态读单例无失效依赖).
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage("ai_avatar_emoji") private var aiAvatarEmoji: String = "🦀"
    @AppStorage("ai_avatar_path") private var aiAvatarPath: String = ""
    @AppStorage("user_avatar_path") private var userAvatarPath: String = ""

    private var path: String {
        role == .ai ? aiAvatarPath : userAvatarPath
    }

    var body: some View {
        ZStack {
            // v2.5: 底层背景同步跟主题切方/圆(防头像图没填满时露出旧圆底), 跟外层 clipShape 同一套圆角逻辑
            RoundedRectangle(cornerRadius: theme.theme == .wechat ? 2 : size / 2, style: .continuous).fill(Color.ccCard)
            if !path.isEmpty, let uiImage = AvatarDiskStore.load(storedValue: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if role == .ai {
                Text(aiAvatarEmoji)
                    .font(.ccSerifAdaptive(size: max(12, size * 0.55), weight: .bold))
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.ccTextDim.opacity(0.65))
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        // v2.2 真机精修: 头像圆角 5->2, 更方更贴真微信近直角方头像 (不是纯 0pt 直角, 留极小圆角). 仅 .wechat 主题, 其它主题仍 Circle 零回归.
        // v2.3 BUG 修: 改用 observe 的 theme.theme (上面 @ObservedObject), 运行时切主题能重算成方/圆.
        // v2.5 BUG 根治: 原来用 AnyShape 三元(类型擦除 Circle/RoundedRectangle), SwiftUI 运行时切主题
        // diff 不出 shape 变化, 头像卡在启动时形状(真机从别主题切进来一直圆; simulator 冷启直接 wechat
        // 才假方). 改成统一 RoundedRectangle, 圆角值在 2(方)和 size/2(圆)间切, 类型不变 SwiftUI 能 diff 能更新.
        .clipShape(RoundedRectangle(cornerRadius: theme.theme == .wechat ? 2 : size / 2, style: .continuous))
        .id("\(role == .ai ? "ai" : "user")-\(AvatarDiskStore.filename(fromStoredValue: path))")
    }
}

enum AvatarImageProcessor {
    nonisolated static func downsample(data: Data, maxPixel: CGFloat = 1024) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return UIImage(data: data) }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func resized(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixel else { return image }
        let scale = maxPixel / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - PHPicker wrapper (SwiftUI)

struct AvatarPHPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: AvatarPHPicker
        init(_ p: AvatarPHPicker) { self.parent = p }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { parent.onPicked(nil); return }
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data {
                    Task.detached(priority: .userInitiated) {
                        let image = AvatarImageProcessor.downsample(data: data, maxPixel: 1024)
                        await MainActor.run {
                            self.parent.onPicked(image)
                        }
                    }
                    return
                }
                if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                    result.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                        let image = (obj as? UIImage).map { AvatarImageProcessor.resized($0, maxPixel: 1024) }
                        DispatchQueue.main.async {
                            self.parent.onPicked(image)
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.parent.onPicked(nil)
                    }
                }
            }
        }
    }
}

// MARK: - Circular crop view

struct AvatarCropView: View {
    let originalImage: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    private let cropDiameter: CGFloat = 280

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                Image(uiImage: originalImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in scale = lastScale * value }
                                .onEnded { _ in lastScale = scale },
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in lastOffset = offset }
                        )
                    )
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, newValue in canvasSize = newValue }
            }

            // Dark overlay with circular cut-out
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .mask(
                    Rectangle()
                        .overlay(
                            RoundedRectangle(cornerRadius: cropDiameter * 0.05, style: .continuous)
                                .frame(width: cropDiameter, height: cropDiameter)
                                .blendMode(.destinationOut)
                        )
                        .compositingGroup()
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // v2.5: 方形取景框(贴微信方头像), 跟存方图 + 显示 clipShape 一致
            RoundedRectangle(cornerRadius: cropDiameter * 0.05, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: cropDiameter, height: cropDiameter)
                .allowsHitTesting(false)

            // Top + bottom action bar
            VStack {
                HStack {
                    Button("取消", action: onCancel)
                        .foregroundStyle(.white)
                        .padding()
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        let cropped = renderCroppedImage()
                        onConfirm(cropped)
                    } label: {
                        Text("确定")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 32)
                            .background(Color.ccAccent)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.bottom, 40)
            }
        }
    }

    /// Render the current view state into a circular UIImage matching the visible crop area.
    /// Uses ImageRenderer on a small composed view sized to cropDiameter.
    private func renderCroppedImage() -> UIImage {
        let renderSize = canvasSize == .zero ? CGSize(width: cropDiameter, height: cropDiameter) : canvasSize
        let render = ImageRenderer(content:
            Image(uiImage: originalImage)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: renderSize.width, height: renderSize.height)
                .background(Color.clear)
        )
        render.scale = UIScreen.main.scale
        guard let full = render.uiImage, let cgImage = full.cgImage else { return originalImage }
        let outputScale = full.scale
        let side = cropDiameter * outputScale
        let rect = CGRect(
            x: max(0, (CGFloat(cgImage.width) - side) / 2),
            y: max(0, (CGFloat(cgImage.height) - side) / 2),
            width: min(side, CGFloat(cgImage.width)),
            height: min(side, CGFloat(cgImage.height))
        )
        guard let croppedCG = cgImage.cropping(to: rect) else { return full }
        let square = UIImage(cgImage: croppedCG, scale: outputScale, orientation: full.imageOrientation)
        let finalSide: CGFloat = 512
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: finalSide, height: finalSide))
        // v2.5 BUG 根治: 原来 ovalIn addClip 把方形 crop 又裁成圆才存盘, 图数据永远圆, 框方了也露圆图.
        // 改成直接存方图, 显示形状全交给 CcAvatarView 的 clipShape 控制(微信方 / 其它圆), 一份方图两主题都对.
        return renderer.image { _ in
            square.draw(in: CGRect(x: 0, y: 0, width: finalSide, height: finalSide))
        }
    }
}

// MARK: - Disk helpers

enum AvatarDiskStore {
    static func documentsURL(filename: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(filename)
    }

    /// Save a UIImage as PNG to documents dir under `filename` (e.g. "cccAvatarAI.png").
    /// Returns filename on success. Persisting only filename survives iOS container path changes.
    @discardableResult
    static func save(_ image: UIImage, filename: String) -> String? {
        let url = documentsURL(filename: filename)
        let normalized = AvatarImageProcessor.resized(image, maxPixel: 512)
        guard let data = normalized.pngData() else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            CcNameResolver.notifyChanged()
            return filename
        } catch {
            return nil
        }
    }

    static func filename(fromStoredValue value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.isFileURL {
            return url.lastPathComponent
        }
        if trimmed.contains("/") {
            return URL(fileURLWithPath: trimmed).lastPathComponent
        }
        return trimmed
    }

    static func load(storedValue: String) -> UIImage? {
        let filename = filename(fromStoredValue: storedValue)
        guard !filename.isEmpty else { return nil }
        return load(filename: filename)
    }

    /// Load a UIImage from documents dir if file exists.
    static func load(filename: String) -> UIImage? {
        let url = documentsURL(filename: filename)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    /// Remove if exists (for "重置头像" future flow).
    static func remove(filename: String) {
        let url = documentsURL(filename: filename)
        try? FileManager.default.removeItem(at: url)
    }

    static func remove(storedValue: String) {
        let filename = filename(fromStoredValue: storedValue)
        guard !filename.isEmpty else { return }
        remove(filename: filename)
    }

    static func migrateStoredAvatarPathsIfNeeded() {
        migrateFilenameDefault(forKey: "ai_avatar_path")
        migrateFilenameDefault(forKey: "user_avatar_path")
        migrateFilenameDefault(forKey: "chat_background_path")
        GroupAvatarStore.migrateLegacyPathsIfNeeded()
    }

    private static func migrateFilenameDefault(forKey key: String) {
        let defaults = UserDefaults.standard
        guard let value = defaults.string(forKey: key), !value.isEmpty else { return }
        let filename = filename(fromStoredValue: value)
        guard !filename.isEmpty, filename != value else { return }
        defaults.set(filename, forKey: key)
    }
}

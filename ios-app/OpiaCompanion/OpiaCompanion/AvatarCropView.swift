//
//  AvatarCropView.swift
//  OpiaCompanion
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
    static let opiaIdentityDidChange = Notification.Name("OpiaIdentityDidChange")
}

enum OpiaIdentityRole {
    case ai
    case user
}

enum OpiaNameResolver {
    static func name(for role: OpiaIdentityRole) -> String {
        switch role {
        case .ai:
            return UserDefaults.standard.string(forKey: "ai_name") ?? OpiaDefaultAIName
        case .user:
            return UserDefaults.standard.string(forKey: "user_name") ?? OpiaDefaultUserName
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
        NotificationCenter.default.post(name: .opiaIdentityDidChange, object: nil)
    }
}

struct OpiaAvatarView: View {
    let role: OpiaIdentityRole
    let size: CGFloat

    @AppStorage("ai_avatar_emoji") private var aiAvatarEmoji: String = "🦀"
    @AppStorage("ai_avatar_path") private var aiAvatarPath: String = ""
    @AppStorage("user_avatar_path") private var userAvatarPath: String = ""

    private var path: String {
        role == .ai ? aiAvatarPath : userAvatarPath
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.opiaCard)
            if !path.isEmpty, let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if role == .ai {
                if UIImage(named: "clawd") != nil {
                    Image("clawd")
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(aiAvatarEmoji)
                        .font(.opiaSerifAdaptive(size: max(12, size * 0.55), weight: .bold))
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.opiaTextDim.opacity(0.65))
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .id("\(role == .ai ? "ai" : "user")-\(path)")
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
                            Circle()
                                .frame(width: cropDiameter, height: cropDiameter)
                                .blendMode(.destinationOut)
                        )
                        .compositingGroup()
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Circular frame outline
            Circle()
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
                            .background(Color.opiaAccent)
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
        return renderer.image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: finalSide, height: finalSide)).addClip()
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
    /// Returns the absolute path on success.
    @discardableResult
    static func save(_ image: UIImage, filename: String) -> String? {
        let url = documentsURL(filename: filename)
        let normalized = AvatarImageProcessor.resized(image, maxPixel: 512)
        guard let data = normalized.pngData() else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            OpiaNameResolver.notifyChanged()
            return url.path
        } catch {
            return nil
        }
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
}

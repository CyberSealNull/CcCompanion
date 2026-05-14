import SwiftUI
import UIKit

struct ImageCropper: View {
    let imageData: Data
    let onComplete: (Data) -> Void
    let onCancel: () -> Void

    @State private var uiImage: UIImage? = nil
    // normalized crop rect [0,1] × [0,1]
    @State private var normRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragStartNorm = CGRect.zero
    @State private var activeHandle: CropHandle? = nil

    private let handleR: CGFloat = 13
    private let minNorm: CGFloat = 0.05

    var body: some View {
        GeometryReader { geo in
            let imgFrame = imageDisplayFrame(geo: geo)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if let img = uiImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imgFrame.width, height: imgFrame.height)
                        .position(x: imgFrame.midX, y: imgFrame.midY)

                    let displayCrop = normToDisplay(normRect, in: imgFrame)
                    CropMaskOverlay(screenSize: geo.size, cropRect: displayCrop)
                    CropBorder(cropRect: displayCrop)
                    cornerHandles(displayCrop: displayCrop, imgFrame: imgFrame)
                    centerDrag(displayCrop: displayCrop, imgFrame: imgFrame)
                }

                // Top bar
                HStack {
                    Button("取消") { onCancel() }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    Spacer()
                    Button("重置") {
                        withAnimation(.spring(response: 0.3)) { normRect = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }

                // Bottom bar
                VStack {
                    Spacer()
                    Button(action: completeCrop) {
                        Text("完成")
                            .font(.opiaSerifAdaptive(size: 17, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 130, height: 46)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .onAppear { uiImage = UIImage(data: imageData) }
    }

    // MARK: - Geometry

    private func imageDisplayFrame(geo: GeometryProxy) -> CGRect {
        guard let img = uiImage, img.size.width > 0, img.size.height > 0 else {
            return CGRect(x: 0, y: 60, width: geo.size.width, height: geo.size.height - 120)
        }
        let availW = geo.size.width
        let availH = geo.size.height - 120
        let imgAspect = img.size.width / img.size.height
        let containerAspect = availW / availH
        var w: CGFloat
        var h: CGFloat
        if imgAspect > containerAspect {
            w = availW
            h = w / imgAspect
        } else {
            h = availH
            w = h * imgAspect
        }
        let x = (geo.size.width - w) / 2
        let y = 60 + (availH - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func normToDisplay(_ norm: CGRect, in imgFrame: CGRect) -> CGRect {
        CGRect(
            x: imgFrame.origin.x + norm.origin.x * imgFrame.width,
            y: imgFrame.origin.y + norm.origin.y * imgFrame.height,
            width: norm.width * imgFrame.width,
            height: norm.height * imgFrame.height
        )
    }

    // MARK: - Corner handles

    private enum CropHandle: Int { case tl, tr, bl, br }

    @ViewBuilder
    private func cornerHandles(displayCrop: CGRect, imgFrame: CGRect) -> some View {
        let corners: [(CropHandle, CGPoint)] = [
            (.tl, CGPoint(x: displayCrop.minX, y: displayCrop.minY)),
            (.tr, CGPoint(x: displayCrop.maxX, y: displayCrop.minY)),
            (.bl, CGPoint(x: displayCrop.minX, y: displayCrop.maxY)),
            (.br, CGPoint(x: displayCrop.maxX, y: displayCrop.maxY))
        ]
        ForEach(corners, id: \.0.rawValue) { handle, pos in
            Circle()
                .fill(Color.white)
                .frame(width: handleR * 2, height: handleR * 2)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .position(pos)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            if activeHandle == nil {
                                activeHandle = handle
                                dragStartNorm = normRect
                            }
                            guard activeHandle == handle else { return }
                            let dx = val.translation.width / imgFrame.width
                            let dy = val.translation.height / imgFrame.height
                            var r = dragStartNorm
                            switch handle {
                            case .tl:
                                let newX = min(r.maxX - minNorm, max(0, r.minX + dx))
                                let newY = min(r.maxY - minNorm, max(0, r.minY + dy))
                                r = CGRect(x: newX, y: newY,
                                           width: dragStartNorm.maxX - newX,
                                           height: dragStartNorm.maxY - newY)
                            case .tr:
                                let newY = min(r.maxY - minNorm, max(0, r.minY + dy))
                                let newW = max(minNorm, min(1 - r.minX, dragStartNorm.width + dx))
                                r = CGRect(x: r.minX, y: newY, width: newW,
                                           height: dragStartNorm.maxY - newY)
                            case .bl:
                                let newX = min(r.maxX - minNorm, max(0, r.minX + dx))
                                let newH = max(minNorm, min(1 - r.minY, dragStartNorm.height + dy))
                                r = CGRect(x: newX, y: r.minY,
                                           width: dragStartNorm.maxX - newX, height: newH)
                            case .br:
                                let newW = max(minNorm, min(1 - r.minX, dragStartNorm.width + dx))
                                let newH = max(minNorm, min(1 - r.minY, dragStartNorm.height + dy))
                                r = CGRect(x: r.minX, y: r.minY, width: newW, height: newH)
                            }
                            normRect = r
                        }
                        .onEnded { _ in activeHandle = nil }
                )
        }
    }

    // MARK: - Center pan drag

    @ViewBuilder
    private func centerDrag(displayCrop: CGRect, imgFrame: CGRect) -> some View {
        Color.clear
            .frame(width: max(displayCrop.width - handleR * 4, 1),
                   height: max(displayCrop.height - handleR * 4, 1))
            .position(x: displayCrop.midX, y: displayCrop.midY)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { val in
                        if activeHandle == nil {
                            activeHandle = .tl  // reuse as "center" sentinel
                            dragStartNorm = normRect
                        }
                        let dx = val.translation.width / imgFrame.width
                        let dy = val.translation.height / imgFrame.height
                        var r = dragStartNorm
                        r.origin.x = max(0, min(1 - r.width, dragStartNorm.origin.x + dx))
                        r.origin.y = max(0, min(1 - r.height, dragStartNorm.origin.y + dy))
                        normRect = r
                    }
                    .onEnded { _ in activeHandle = nil }
            )
    }

    // MARK: - Crop + complete

    private func completeCrop() {
        guard let img = uiImage else { onCancel(); return }
        let pixelRect = CGRect(
            x: normRect.origin.x * img.size.width,
            y: normRect.origin.y * img.size.height,
            width: normRect.width * img.size.width,
            height: normRect.height * img.size.height
        )
        let data = cropUIImage(img, to: pixelRect)?.jpegData(compressionQuality: 0.9) ?? imageData
        onComplete(data)
    }

    private func cropUIImage(_ image: UIImage, to rect: CGRect) -> UIImage? {
        let scale = image.scale
        let scaledRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        guard let cg = image.cgImage?.cropping(to: scaledRect) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: image.imageOrientation)
    }
}

// MARK: - Overlay views

private struct CropMaskOverlay: View {
    let screenSize: CGSize
    let cropRect: CGRect

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(cropRect)
                },
                with: .color(Color.black.opacity(0.55)),
                style: FillStyle(eoFill: true)
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct CropBorder: View {
    let cropRect: CGRect

    var body: some View {
        Canvas { ctx, _ in
            // Outer border
            ctx.stroke(
                Path { p in p.addRect(cropRect) },
                with: .color(.white),
                lineWidth: 1.5
            )
            // Rule-of-thirds grid
            let x1 = cropRect.minX + cropRect.width / 3
            let x2 = cropRect.minX + cropRect.width * 2 / 3
            let y1 = cropRect.minY + cropRect.height / 3
            let y2 = cropRect.minY + cropRect.height * 2 / 3
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: x1, y: cropRect.minY))
                    p.addLine(to: CGPoint(x: x1, y: cropRect.maxY))
                    p.move(to: CGPoint(x: x2, y: cropRect.minY))
                    p.addLine(to: CGPoint(x: x2, y: cropRect.maxY))
                    p.move(to: CGPoint(x: cropRect.minX, y: y1))
                    p.addLine(to: CGPoint(x: cropRect.maxX, y: y1))
                    p.move(to: CGPoint(x: cropRect.minX, y: y2))
                    p.addLine(to: CGPoint(x: cropRect.maxX, y: y2))
                },
                with: .color(Color.white.opacity(0.35)),
                lineWidth: 0.5
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

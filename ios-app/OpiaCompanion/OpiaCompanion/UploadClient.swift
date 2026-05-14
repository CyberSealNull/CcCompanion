import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum ImageCompressor {
    static func compress(data: Data, maxLength: CGFloat = 1920, quality: CGFloat = 0.85) -> Data {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxLength else {
            return image.jpegData(compressionQuality: quality) ?? data
        }
        let scale = maxLength / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality) ?? data
        #else
        return data
        #endif
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

enum UploadClient {
    static func upload(
        request: URLRequest,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        let delegate = UploadProgressDelegate(progress: progress)
        return try await URLSession.shared.upload(for: request, from: data, delegate: delegate)
    }
}

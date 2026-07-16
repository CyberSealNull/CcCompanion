//
//  PushTokenManager.swift
//  CcCompanion
//
//  Standard remote notification device token.
//
//  Registers for APNs and uploads the device hex token to backend POST /register-device-token.
//

#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import UserNotifications
import OSLog
import DirectAPICore

@MainActor
final class PushTokenManager {
    static let shared = PushTokenManager()

    var serverURL: URL { CcServerConfig.serverURL }
    var sharedSecret: String? { CcServerConfig.sharedSecret }

    private let logger = Logger(subsystem: "com.starryfield.CcCompanion", category: "DevicePushToken")
    // 二审(P0-2): 这枚自建 session 也在 fresh probe 点名的漏网名单里, 经 ccGuarded() 工厂显式注入
    // guard protocol —— _post 里已有的 DirectAPIConfig.isActive 早退是功能层门, 这里是网络层兜底.
    private let session: URLSession = {
        let cfg = DirectAPIServerGuardProtocol.ccGuarded()
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    private var lastTokenHex: String?

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func registerDeviceToken(_ tokenData: Data) async {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        lastTokenHex = hex
        let aiName = UserDefaults.standard.string(forKey: "ai_name") ?? CcDefaultAIName
        await _post(token: hex, aiName: aiName)
    }

    /// Call when the user changes ai_name in Settings to keep backend in sync.
    func updateAIName(_ newName: String) async {
        guard let hex = lastTokenHex else { return }
        await _post(token: hex, aiName: newName)
    }

    private func _post(token: String, aiName: String) async {
        // P0 直连(code review P0-2): 门 B 全新用户没有 server, 不该把 device token 发给 placeholder/遗留配置.
        guard !DirectAPIConfig.isActive else { return }
        logger.info("registering device token len=\(token.count) ai_name=\(aiName, privacy: .public)")
        let url = serverURL.appendingPathComponent("register-device-token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["token": token, "ai_name": aiName]) else { return }
        req.httpBody = body
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                logger.info("register-device-token status=\(http.statusCode)")
            }
        } catch {
            logger.error("register-device-token failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif

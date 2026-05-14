//
//  PushTokenManager.swift
//  OpiaCompanion
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

@MainActor
final class PushTokenManager {
    static let shared = PushTokenManager()

    var serverURL: URL { OpiaServerConfig.serverURL }
    var sharedSecret: String? { OpiaServerConfig.sharedSecret }

    private let logger = Logger(subsystem: "com.starryfield.OpiaCompanion", category: "DevicePushToken")
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

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
        logger.info("registering device token len=\(hex.count)")
        let url = serverURL.appendingPathComponent("register-device-token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = sharedSecret, !secret.isEmpty {
            req.setValue(secret, forHTTPHeaderField: "X-Auth-Token")
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["token": hex]) else { return }
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

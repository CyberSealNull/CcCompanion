//
//  AppDelegate.swift
//  OpiaCompanion
//
//  Handles standard remote notification lifecycle:
//  - didRegisterForRemoteNotificationsWithDeviceToken → PushTokenManager uploads hex token
//  - didFailToRegisterForRemoteNotifications → log only
//  - didReceiveRemoteNotification (content-available silent push) → no-op for now
//  - UNUserNotificationCenterDelegate.willPresent → show banner even in foreground
//

import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Task {
            await PushTokenManager.shared.registerDeviceToken(deviceToken)
        }
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[PushToken] didFailToRegisterForRemoteNotifications: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        completionHandler(.newData)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // build 93: 应用前台不弹 banner / 不响声 静默进通知中心 (badge 仍更新)
        completionHandler([.list, .badge])
    }
}

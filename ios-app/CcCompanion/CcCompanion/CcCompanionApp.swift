//
//  CcCompanionApp.swift
//  CcCompanion
//
//  Created by HoshimiMian on 2026/4/28.
//

import SwiftUI
import UIKit
import CoreText

@main
struct CcCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Build 218 r3 — XCUITest hook: when launched with UITEST_GROUP_UPLOAD_SMOKE=1
        // pre-populate UserDefaults so the test skips onboarding + lands directly on the
        // group chat tab pointed at the local demo server (8796). Has no effect at runtime.
        if ProcessInfo.processInfo.environment["UITEST_GROUP_UPLOAD_SMOKE"] == "1" {
            // Onboarding flag + feature toggle live in standard suite (per @AppStorage usage).
            let std = UserDefaults.standard
            std.set(true, forKey: "cc_onboarding_completed")
            std.set(true, forKey: "feature_group_view")
            std.set("",   forKey: "chat_last_seen_ts")
            // Server endpoint list lives in the app group suite (per CcServerConfig).
            if let ag = UserDefaults(suiteName: CcServerConfig.appGroup) {
                ag.set(["http://127.0.0.1:8796"], forKey: "serverURLList")
                ag.set(["UITestDemo"],             forKey: "serverLabelList")
                ag.set(0,                          forKey: "serverActiveIndex")
                ag.set("http://127.0.0.1:8796",    forKey: "serverURL")
            }
            // Shared secret read from launchEnvironment (UITest injects via XCUIApplication.launchEnvironment).
            // Never hardcode a secret literal here — public repo leaks it (incident 2026-05-24).
            if let injected = ProcessInfo.processInfo.environment["CCC_UITEST_SHARED_SECRET"], !injected.isEmpty {
                CcServerConfig.setSharedSecret(injected)
            }
        }
        // Phase multi-server fallback (2026-05-11) — 旧版单 serverURL 一次性迁到新 endpoints 列表.
        CcServerConfig.migrateLegacySharedSecretIfNeeded()
        CcServerConfig.migrateLegacySingleURLIfNeeded()
        CcServerConfig.syncToAppGroup()
        AvatarDiskStore.migrateStoredAvatarPathsIfNeeded()
        Self.registerCustomFonts()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Task { @MainActor in
            PushTokenManager.shared.requestAuthorization()
        }
        #endif
    }

    private static func registerCustomFonts() {
        let names = [
            "SourceSerif4-Regular",
            "SourceSerif4-Semibold",
            "SourceHanSerifSC-Regular",
            "SourceHanSerifSC-Bold",
        ]
        for n in names {
            guard let url = Bundle.main.url(forResource: n, withExtension: "otf") else {
                print("[CcFont] missing in bundle: \(n).otf")
                continue
            }
            var err: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                print("[CcFont] register failed \(n): \(err.debugDescription)")
            }
        }
        let han = UIFont.fontNames(forFamilyName: "Source Han Serif SC")
        let serif = UIFont.fontNames(forFamilyName: "Source Serif 4")
        print("[CcFont] Source Han Serif SC fonts = \(han)")
        print("[CcFont] Source Serif 4 fonts = \(serif)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ccSerifTheme()
                .whatsNewGate()   // v1.2 新 build 首启弹 What's New
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("Paste") {
                    NotificationCenter.default.post(name: .ccPasteFromClipboard, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let ccPasteFromClipboard = Notification.Name("ccPasteFromClipboard")
}

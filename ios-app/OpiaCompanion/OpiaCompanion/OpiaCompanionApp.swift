//
//  OpiaCompanionApp.swift
//  OpiaCompanion
//
//  Created by HoshimiMian on 2026/4/28.
//

import SwiftUI
import UIKit
import CoreText

@main
struct OpiaCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Phase multi-server fallback (2026-05-11) — 旧版单 serverURL 一次性迁到新 endpoints 列表.
        OpiaServerConfig.migrateLegacySingleURLIfNeeded()
        OpiaServerConfig.syncToAppGroup()
        Self.registerCustomFonts()
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
                print("[OpiaFont] missing in bundle: \(n).otf")
                continue
            }
            var err: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                print("[OpiaFont] register failed \(n): \(err.debugDescription)")
            }
        }
        let han = UIFont.fontNames(forFamilyName: "Source Han Serif SC")
        let serif = UIFont.fontNames(forFamilyName: "Source Serif 4")
        print("[OpiaFont] Source Han Serif SC fonts = \(han)")
        print("[OpiaFont] Source Serif 4 fonts = \(serif)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .opiaSerifTheme()
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("Paste") {
                    NotificationCenter.default.post(name: .opiaPasteFromClipboard, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let opiaPasteFromClipboard = Notification.Name("opiaPasteFromClipboard")
}

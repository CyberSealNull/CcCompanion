//
//  WizardStepWelcome.swift
//  OpiaCompanion
//
//  CcCompanion onboarding wizard — Step 0: Welcome (intro + supported platforms).
//  Spec: cccompanion_wizard_welcome_setup_phase_b_20260511.md
//

import SwiftUI

struct WizardStepWelcome: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("CcCompanion")
                .font(.opiaSerifAdaptive(size: 32, weight: .bold))
                .foregroundStyle(Color.opiaText)
                .padding(.bottom, 14)

            // Illustration placeholder — SF Symbol per spec
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.opiaAccent)
                .padding(.bottom, 24)

            Text("CcCompanion 是 Claude Code 的 iOS 远程客户端，server 跑在你的 macOS、Windows、Linux 或云服务器上，你在任何地方用 iPhone 都能远程控制。")
                .font(.opiaSerifAdaptive(size: 15))
                .foregroundStyle(Color.opiaText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 24)

            Spacer()

            Button {
                triggerLocalNetworkPermission()
                onContinue()
            } label: {
                Text("开始配置")
                    .font(.opiaSerifAdaptive(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.opiaAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.bottom, 36)
        }
        .padding(.horizontal, 28)
    }

    /// Phase C — fire a dummy LAN request to trigger iOS NSLocalNetworkUsageDescription dialog
    /// before user reaches the server URL step. Otherwise first real LAN access fails silently
    /// while iOS waits for permission grant.
    private func triggerLocalNetworkPermission() {
        guard let url = URL(string: "http://192.168.1.1") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        let task = URLSession.shared.dataTask(with: req) { _, _, _ in /* ignore */ }
        task.resume()
    }
}

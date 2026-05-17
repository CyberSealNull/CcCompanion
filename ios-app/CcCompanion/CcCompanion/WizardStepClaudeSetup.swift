//
//  WizardStepClaudeSetup.swift
//  CcCompanion
//
//  CcCompanion onboarding wizard — Step 1: Claude server setup prompt + 复制按钮.
//  Spec: cccompanion_wizard_welcome_setup_phase_b_20260511.md
//

import SwiftUI
import UIKit

struct WizardStepClaudeSetup: View {
    let onContinue: () -> Void

    @State private var copiedToast: Bool = false

    private static let claudeSetupPrompt = """
请帮我装 CcCompanion 开源 server。从 github.com/CyberSealNull/CcCompanion git clone 到 ~/CcCompanion，cd 进 apns-server 目录，pip install -r requirements.txt，启动 push.py 监听 8795 端口（如果占用就换 8796），打印 server 内网 URL（http://你的内网 IP:8795）和自动生成的 shared_secret，告诉我我要在 CcCompanion wizard 里输入这两个。
"""

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12)

            Text("Claude 帮你装 server")
                .font(.ccSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.ccText)
                .padding(.bottom, 6)

            Text("你需要在你的 macOS / Windows / Linux / 云服务器 上跑一份 CcCompanion server，让 iPhone 可以连上。把下面这段话复制给你 mac 上的 Claude Code 终端，Claude 会自动帮你装好。")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .padding(.horizontal, 4)
                .padding(.bottom, 18)

            // Prompt 框
            ScrollView(.vertical, showsIndicators: true) {
                Text(Self.claudeSetupPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.ccText)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 200)
            .background(Color.ccCard)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 12)

            // 复制按钮
            Button {
                UIPasteboard.general.string = Self.claudeSetupPrompt
                withAnimation(.easeOut(duration: 0.15)) { copiedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.2)) { copiedToast = false }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copiedToast ? "checkmark.circle.fill" : "doc.on.clipboard")
                    Text(copiedToast ? "已复制" : "复制 prompt")
                }
                .font(.ccSerifAdaptive(size: 14, weight: .medium))
                .foregroundStyle(copiedToast ? Color.green : Color.ccAccent)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.ccCard.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Text("复制后回到 Claude Code 终端粘贴运行")
                .font(.ccSerifAdaptive(size: 12))
                .foregroundStyle(Color.ccTextDim)
                .padding(.top, 12)

            Spacer()

            Button(action: onContinue) {
                Text("我已复制，下一步")
                    .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.ccAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.bottom, 36)
        }
        .padding(.horizontal, 28)
    }
}

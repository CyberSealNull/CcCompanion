//
//  WizardStepChoosePath.swift
//  CcCompanion
//
//  P0 直连 onboarding 分岔: Welcome 之后, ClaudeSetup(门 A)之前插入的选择步.
//  门 A 走原样 step 1→6 逐字节不变; 门 B 走新的 DirectAPI 设置步.
//

import SwiftUI

struct WizardStepChoosePath: View {
    let onChooseCcServer: () -> Void
    let onChooseDirectAPI: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("怎么开始")
                .font(.ccSerifAdaptive(size: 24, weight: .bold))
                .foregroundStyle(Color.ccText)
                .padding(.bottom, 8)
            Text("两条路都能聊, 随时能在设置页切换")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccTextDim)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                pathCard(
                    icon: "desktopcomputer",
                    title: "我有 Claude Code / 连自己的服务器",
                    subtitle: "在自己的 Mac / 服务器跑 CcCompanion server, 功能最全",
                    action: onChooseCcServer
                )
                pathCard(
                    icon: "bolt.fill",
                    title: "先快速体验",
                    subtitle: "填一个 API key 直接聊, 不用装 server, 官方 API 直连",
                    action: onChooseDirectAPI
                )
            }
            .padding(.horizontal, 4)

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func pathCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.ccAccent)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ccText)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.ccSerifAdaptive(size: 12))
                        .foregroundStyle(Color.ccTextDim)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ccTextDim)
            }
            .padding(16)
            .background(Color.ccCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

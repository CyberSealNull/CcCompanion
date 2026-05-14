//
//  FloatingTabBar.swift
//  OpiaCompanion
//
//  浮岛风 tab bar — 圆角悬浮 + 横向滚动 (容纳 9 个 tab) + 选中态橙色胶囊.
//  用户 push 2026-05-05 22:48 选了方向一.
//

import SwiftUI

#if os(iOS)

enum BadgeStyle: Equatable, Hashable {
    case none
    case unreadDot      // 普通红点 — 有未读消息
    case mentionAt      // 红色 @ — 被 @amian
    case count(Int)     // 数字角标 留扩展
}

struct FloatingTabBarItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let systemImage: String
    var badge: BadgeStyle = .none
}

struct FloatingTabBar: View {
    let items: [FloatingTabBarItem]
    @Binding var selection: Int
    // 2026-05-14 build 191 — 订阅 ThemeStore, ContentView 不再用 .id(theme) 强制重建后
    // 这里需要自己 observe 才能在切主题时刷颜色.
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        // tab 数 <= 5 时用 HStack 平均分布 (撑满) > 5 时用 ScrollView 横向滚动 (兼容旧 9 tab)
        let useEvenLayout = items.count <= 5
        return Group {
            if useEvenLayout {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        tabButton(for: item)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.opiaFloatingBarBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Color.opiaAssistant.opacity(0.08), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(items) { item in
                                tabButton(for: item)
                                    .frame(minWidth: 56)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.opiaFloatingBarBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(Color.opiaAssistant.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .onChange(of: selection) { _, new in
                        withAnimation { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tabButton(for item: FloatingTabBarItem) -> some View {
        let isActive = item.id == selection
        // 2026-05-09 用户 push Mac Catalyst 配色 + 字号 终端风
        // iPhone: 选中橙色 + 透明胶囊背景 (旧)
        // Mac: 选中实色橙色胶囊 + 白字 (高对比 终端风) + 字号大一档防糊
        // Phase F (item 4) 2026-05-11 — terminal 主题下 opiaAssistant=clear 导致 active fg/bg 全消失.
        // 改用 opiaAccent (每个主题都有可见 accent: warm 橙 / terminal 浅青 / night 暖橙).
        // inactive 走 opiaText (而非 opiaTextDim, 终端 dim 太灰看不清).
        #if targetEnvironment(macCatalyst)
        let iconSize: CGFloat = 22
        let titleSize: CGFloat = 13
        let activeBg: Color = Color.opiaAccent
        let activeFg: Color = Color.opiaBg          // active capsule 上要跟胶囊 bg 反差
        let inactiveFg: Color = Color.opiaText
        let titleDesign: Font.Design = .monospaced
        #else
        let iconSize: CGFloat = 20  // Phase D bumped 18 → 20 (用户 push tab bar 太窄)
        let titleSize: CGFloat = 11  // 10 → 11
        let activeBg: Color = Color.opiaAccent.opacity(0.18)
        let activeFg: Color = Color.opiaAccent
        let inactiveFg: Color = Color.opiaFloatingBarText  // T1 fix: warm 主题下系统 dark 不再压成黑色 → 文字也跟着 fixed
        let titleDesign: Font.Design = .default
        #endif
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                selection = item.id
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.systemImage)
                    .font(.system(size: iconSize, weight: isActive ? .semibold : .regular))
                    .overlay(alignment: .topTrailing) {
                        badgeView(for: item.badge)
                            .offset(x: 5, y: -5)
                    }
                Text(item.title)
                    .font(.system(size: titleSize, weight: isActive ? .bold : .medium, design: titleDesign))
            }
            .foregroundStyle(isActive ? activeFg : inactiveFg)
            .padding(.vertical, 8)  // Phase D 6 → 8 (用户 push tab bar 太窄)
            .padding(.horizontal, 14)  // 10 → 14
            .background(
                Capsule()
                    .fill(isActive ? activeBg : Color.clear)
            )
            .id(item.id)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func badgeView(for style: BadgeStyle) -> some View {
        switch style {
        case .none:
            EmptyView()
        case .unreadDot:
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
        case .mentionAt:
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 14, height: 14)
                Text("@")
                    .font(.opiaSerifAdaptive(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .count(let n):
            Text("\(n)")
                .font(.opiaSerifAdaptive(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .background(Capsule().fill(Color.red))
        }
    }
}

#endif

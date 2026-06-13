//
//  FloatingTabBar.swift
//  CcCompanion
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
                        .fill(Color.ccFloatingBarBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Color.ccAssistant.opacity(0.08), lineWidth: 0.5)
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
                            .fill(Color.ccFloatingBarBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(Color.ccAssistant.opacity(0.08), lineWidth: 0.5)
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
        // Phase F (item 4) 2026-05-11 — terminal 主题下 ccAssistant=clear 导致 active fg/bg 全消失.
        // 改用 ccAccent (每个主题都有可见 accent: warm 橙 / terminal 浅青 / night 暖橙).
        // inactive 走 ccText (而非 ccTextDim, 终端 dim 太灰看不清).
        #if targetEnvironment(macCatalyst)
        let iconSize: CGFloat = 22
        let titleSize: CGFloat = 13
        let activeBg: Color = Color.ccAccent
        let activeFg: Color = Color.ccBg          // active capsule 上要跟胶囊 bg 反差
        let inactiveFg: Color = Color.ccText
        let titleDesign: Font.Design = .monospaced
        #else
        let iconSize: CGFloat = 20  // Phase D bumped 18 → 20 (用户 push tab bar 太窄)
        let titleSize: CGFloat = 11  // 10 → 11
        let activeBg: Color = Color.ccAccent.opacity(0.18)
        let activeFg: Color = Color.ccAccent
        let inactiveFg: Color = Color.ccFloatingBarText  // T1 fix: warm 主题下系统 dark 不再压成黑色 → 文字也跟着 fixed
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
        // Build 218 r3 — XCUITest hook: stable identifier per tab so smoke tests
        // can tap `app.buttons["tab-\(item.id)"]` regardless of locale or icon name.
        .accessibilityIdentifier("tab-\(item.id)")
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
                    .font(.ccSerifAdaptive(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .count(let n):
            Text("\(n)")
                .font(.ccSerifAdaptive(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .background(Capsule().fill(Color.red))
        }
    }
}

struct WeChatTabBar: View {
    let items: [FloatingTabBarItem]
    @Binding var selection: Int

    private let wechatGreen = Color(red: 0.027, green: 0.756, blue: 0.376)
    private let inactiveGray = Color(red: 0.478, green: 0.478, blue: 0.478)
    private let barBg = Color(red: 0.969, green: 0.969, blue: 0.969)
    private let hairline = Color(red: 0.898, green: 0.898, blue: 0.898)

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(hairline)
                .frame(height: 0.5)
            HStack(spacing: 0) {
                ForEach(items) { item in
                    let isActive = item.id == selection
                    Button {
                        selection = item.id
                    } label: {
                        VStack(spacing: 3) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: isActive ? fillVariant(item.systemImage) : item.systemImage)
                                    .font(.system(size: 22))
                                    .foregroundStyle(isActive ? wechatGreen : inactiveGray)
                                wechatBadge(for: item.badge)
                                    .offset(x: 6, y: -4)
                            }
                            Text(item.title)
                                .font(.system(size: 10))
                                .foregroundStyle(isActive ? wechatGreen : inactiveGray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tab-\(item.id)")
                }
            }
            .padding(.bottom, 2)
        }
        .background(barBg)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func fillVariant(_ name: String) -> String {
        let fillName = name.hasSuffix(".fill") ? name : name + ".fill"
        if UIImage(systemName: fillName) != nil { return fillName }
        return name
    }

    @ViewBuilder
    private func wechatBadge(for style: BadgeStyle) -> some View {
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
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .count(let n):
            Text("\(n)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.red))
        }
    }
}

#endif

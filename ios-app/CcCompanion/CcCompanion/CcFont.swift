import SwiftUI

extension Font {
    /// Mac Catalyst: fallback to system SF Pro at +20% size for sharper rendering; iOS: use CcSerif (STSongti-SC)
    /// WeChat theme: always system font (spec item 6)
    static func ccSerifAdaptive(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if ThemeStore.shared.theme == .wechat {
            return Font.system(size: size, weight: weight, design: .default)
        }
        #if targetEnvironment(macCatalyst)
        return Font.system(size: size * 1.2, weight: weight, design: .default)
        #else
        return ccSerif(size: size, weight: weight)
        #endif
    }

    static func ccSerif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // 2026-05-07 临时验证 build 99 用 iOS 内置 Songti SC (不依赖 custom font register)
        // 装上中文变宋体 = .font 替换路径通 是 SourceHanSerifSC register 问题
        // 装上还没变 = 替换本身没真生效 (build 配置 / view 自带 .font 覆盖)
        let name: String
        switch weight {
        case .bold, .heavy, .black, .semibold:
            name = "STSongti-SC-Bold"
        default:
            name = "STSongti-SC-Regular"
        }
        return .custom(name, size: size)
    }

    static func ccSerifEn(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black, .semibold:
            name = "SourceSerif4-Semibold"
        default:
            name = "SourceSerif4-Regular"
        }
        return .custom(name, size: size)
    }
}

struct CcSerifModifier: ViewModifier {
    // 2026-06-13 字体响应式修复: 必须 @ObservedObject 才能在切主题时重算 body.
    // 之前静态读 ThemeStore.shared.theme 没登记 SwiftUI 依赖, 进过微信主题(字体=system)
    // 切回暖橙/夜间字体卡在 system 不回 serif.
    @ObservedObject private var themeStore = ThemeStore.shared
    func body(content: Content) -> some View {
        if themeStore.theme == .wechat {
            content
                .font(.system(size: 17))
        } else {
            content
                .fontDesign(.serif)
                .font(.ccSerifAdaptive(size: 17))
        }
    }
}

extension View {
    func ccSerifTheme() -> some View {
        modifier(CcSerifModifier())
    }
}

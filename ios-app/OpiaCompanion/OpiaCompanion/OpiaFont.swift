import SwiftUI

extension Font {
    /// Mac Catalyst: fallback to system SF Pro at +20% size for sharper rendering; iOS: use OpiaSerif (STSongti-SC)
    static func opiaSerifAdaptive(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if targetEnvironment(macCatalyst)
        return Font.system(size: size * 1.2, weight: weight, design: .default)
        #else
        return opiaSerif(size: size, weight: weight)
        #endif
    }

    static func opiaSerif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
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

    static func opiaSerifEn(size: CGFloat, weight: Font.Weight = .regular) -> Font {
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

struct OpiaSerifModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .fontDesign(.serif)
            .font(.opiaSerifAdaptive(size: 17))
    }
}

extension View {
    func opiaSerifTheme() -> some View {
        modifier(OpiaSerifModifier())
    }
}

//
//  DirectAPIProvider.swift
//  DirectAPICore
//
//  纯逻辑, 不依赖 UIKit/app 状态 —— 可独立 `swift test`, 也被 app target 当依赖引用.
//

public enum DirectAPIProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAICompat = "openai_compat"
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAICompat: return "OpenAI 兼容"
        case .other: return "其它"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openAICompat: return "gpt-5.6"
        case .other: return ""
        }
    }

    /// 「其它」走 OpenAI 兼容报文, 区别只在 UI 不预填 URL/model.
    /// 报文格式与 baseURL 需求的判断一律用这两个语义属性, 不散落 == 比较, 再加档不漏改.
    public var usesOpenAICompatWire: Bool {
        switch self {
        case .anthropic: return false
        case .openAICompat, .other: return true
        }
    }

    public var needsBaseURL: Bool { usesOpenAICompatWire }
}

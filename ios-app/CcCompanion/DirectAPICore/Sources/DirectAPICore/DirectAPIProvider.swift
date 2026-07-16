//
//  DirectAPIProvider.swift
//  DirectAPICore
//
//  纯逻辑, 不依赖 UIKit/app 状态 —— 可独立 `swift test`, 也被 app target 当依赖引用.
//

public enum DirectAPIProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAICompat = "openai_compat"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAICompat: return "OpenAI 兼容"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openAICompat: return "gpt-4o"
        }
    }
}

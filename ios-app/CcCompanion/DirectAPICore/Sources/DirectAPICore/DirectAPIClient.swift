//
//  DirectAPIClient.swift
//  DirectAPICore
//
//  统一 provider 接口 + baseURL 安全校验. code review P0-3/P0-4: 这是真正的安全边界(HTTPS 校验)
//  跟可复跑单测的落点(原先 app target 里同名文件的逻辑原样搬进包, 加 public 访问级别).
//

import Foundation

public struct DirectAPIMessage: Sendable {
    public let role: String  // "user" | "assistant"
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum DirectAPIError: LocalizedError, Equatable, Sendable {
    case missingKey
    case unauthorized
    case rateLimited
    case network(String)
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "没有配置 API key, 去设置页填一个"
        case .unauthorized: return "API key 无效或已过期, 去设置页检查"
        case .rateLimited: return "请求太频繁, 稍等一下再试"
        case .network(let msg): return "网络连不上: \(msg)"
        case .server(let status, let message): return "服务端返回错误 (\(status)): \(message)"
        }
    }
}

public protocol DirectAPIProviderAdapting: Sendable {
    func streamChat(messages: [DirectAPIMessage], system: String, apiKey: String, model: String) -> AsyncThrowingStream<String, Error>
    func testConnection(apiKey: String, model: String) async -> Result<Void, DirectAPIError>
}

/// code review P0-3: OpenAI-compat baseURL 明文 http:// 配合 app 的 NSAllowsArbitraryLoads=true 会让
/// Bearer key 在网络上被截获. 只许 https, 或显式 loopback 例外(产品决策: localhost/127.0.0.1/::1,
/// 局域网 IP 不算例外——诉求等真用户提了再议).
public enum BaseURLValidationError: LocalizedError, Sendable {
    case malformed
    case notHTTPS
    case emptyHost
    case hasUserInfo

    public var errorDescription: String? {
        switch self {
        case .malformed: return "baseURL 格式不对"
        case .notHTTPS: return "baseURL 必须是 https:// 开头(明文 http 会让 key 在网络上被截获, 仅本机 localhost/127.0.0.1 例外)"
        case .emptyHost: return "baseURL 缺少域名"
        case .hasUserInfo: return "baseURL 不能带用户名密码"
        }
    }
}

public enum DirectAPIClient {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// 唯一的安全边界: 两个 adapter 的 endpoint() 都必须先过这一关, 校验没过直接返回错误——
    /// 调用方在这一步失败后立刻 return, 不能继续往下构造带 Authorization header 的 URLRequest.
    public static func validateBaseURL(_ raw: String) -> Result<URL, BaseURLValidationError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .failure(.malformed)
        }
        guard let host = url.host, !host.isEmpty else { return .failure(.emptyHost) }
        guard url.user == nil, url.password == nil else { return .failure(.hasUserInfo) }
        if scheme == "https" { return .success(url) }
        if scheme == "http", loopbackHosts.contains(host.lowercased()) { return .success(url) }
        return .failure(.notHTTPS)
    }

    public static func adapter(for provider: DirectAPIProvider, baseURL: String) -> DirectAPIProviderAdapting {
        switch provider {
        case .anthropic: return AnthropicAdapter()
        case .openAICompat, .other: return OpenAICompatAdapter(baseURL: baseURL)
        }
    }

    /// 流式发送. 调用方(app 的 ChatViewModel.sendDirectAPI)负责从自己的存储层读 provider/baseURL/
    /// model/apiKey 再传进来 —— 这个包本身不认识 app 的 DirectAPIConfig/Keychain, 保持纯逻辑可移植.
    public static func streamChat(
        messages: [DirectAPIMessage], system: String,
        provider: DirectAPIProvider, baseURL: String, model: String, apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: DirectAPIError.missingKey) }
        }
        return adapter(for: provider, baseURL: baseURL).streamChat(messages: messages, system: system, apiKey: apiKey, model: model)
    }

    /// onboarding 门 B / 设置页「测试连通」共用: 非流式最小请求验证 key+baseURL+model.
    public static func testConnection(provider: DirectAPIProvider, baseURL: String, model: String, apiKey: String) async -> Result<Void, DirectAPIError> {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.missingKey) }
        let a = adapter(for: provider, baseURL: baseURL)
        return await a.testConnection(apiKey: apiKey, model: model)
    }

    public static func classifyHTTPError(status: Int, body: String) -> DirectAPIError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default:
            let msg = extractErrorMessage(fromJSON: body) ?? body
            return .server(status: status, message: msg.isEmpty ? "HTTP \(status)" : msg)
        }
    }

    private static func extractErrorMessage(fromJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        return nil
    }

    /// 非 2xx 响应体收集(截断防超长), 供 classifyHTTPError 提取人话.
    public static func collectBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var text = ""
        do {
            for try await line in bytes.lines {
                text += line
                if text.count > 2000 { break }
            }
        } catch {
            // ignore — 拿到多少算多少, 用于错误展示不影响主流程
        }
        return text
    }
}

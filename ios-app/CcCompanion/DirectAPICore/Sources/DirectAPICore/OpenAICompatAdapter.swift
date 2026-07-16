//
//  OpenAICompatAdapter.swift
//  DirectAPICore
//
//  {baseURL}/chat/completions, SSE stream, Bearer 头. baseURL 用户可改(默认 api.openai.com/v1),
//  一个 adapter 覆盖 OpenAI / GLM / DeepSeek / 任意兼容网关. endpoint() 是唯一的安全边界(code review
//  P0-3): HTTPS(或显式 loopback 例外)校验没过, 直接返回错误——调用方必须在这一步失败后立刻 return,
//  不能继续往下构造带 Authorization header 的 URLRequest.
//

import Foundation

public struct OpenAICompatAdapter: DirectAPIProviderAdapting {
    let baseURL: String

    public init(baseURL: String) {
        self.baseURL = baseURL
    }

    private func endpoint() -> Result<URL, DirectAPIError> {
        switch DirectAPIClient.validateBaseURL(baseURL) {
        case .success(let base):
            return .success(base.appendingPathComponent("chat/completions"))
        case .failure(let err):
            return .failure(.network(err.errorDescription ?? "baseURL 格式错误"))
        }
    }

    public func streamChat(messages: [DirectAPIMessage], system: String, apiKey: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url: URL
                    switch endpoint() {
                    case .success(let u): url = u
                    case .failure(let err):
                        continuation.finish(throwing: err)
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 60
                    var apiMessages: [[String: String]] = [["role": "system", "content": system]]
                    apiMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })
                    let body: [String: Any] = ["model": model, "messages": apiMessages, "stream": true]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: DirectAPIError.network("无响应"))
                        return
                    }
                    guard (200...299).contains(http.statusCode) else {
                        let errText = await DirectAPIClient.collectBody(bytes)
                        continuation.finish(throwing: DirectAPIClient.classifyHTTPError(status: http.statusCode, body: errText))
                        return
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else { continue }
                        if let text = chunk.choices.first?.delta.content, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let err as DirectAPIError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: DirectAPIError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection(apiKey: String, model: String) async -> Result<Void, DirectAPIError> {
        let url: URL
        switch endpoint() {
        case .success(let u): url = u
        case .failure(let err): return .failure(err)
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 8]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.network("无响应")) }
            guard (200...299).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                return .failure(DirectAPIClient.classifyHTTPError(status: http.statusCode, body: text))
            }
            return .success(())
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

struct OpenAIStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
        struct Delta: Decodable {
            let content: String?
        }
    }
}

//
//  AnthropicAdapter.swift
//  DirectAPICore
//
//  api.anthropic.com/v1/messages, SSE stream, x-api-key 头.
//

import Foundation

public struct AnthropicAdapter: DirectAPIProviderAdapting {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"

    public init() {}

    public func streamChat(messages: [DirectAPIMessage], system: String, apiKey: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 60
                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "system": system,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "stream": true,
                    ]
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
                        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                        guard let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else { continue }
                        if event.type == "content_block_delta", let text = event.delta?.text {
                            continuation.yield(text)
                        } else if event.type == "error" {
                            let msg = event.error?.message ?? "unknown error"
                            continuation.finish(throwing: DirectAPIError.server(status: 0, message: msg))
                            return
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
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 8,
                "messages": [["role": "user", "content": "hi"]],
            ]
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

struct AnthropicStreamEvent: Decodable {
    let type: String
    let delta: Delta?
    let error: APIError?

    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
    struct APIError: Decodable {
        let type: String?
        let message: String?
    }
}

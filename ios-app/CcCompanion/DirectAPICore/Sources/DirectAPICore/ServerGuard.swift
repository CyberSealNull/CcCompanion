//
//  ServerGuard.swift
//  DirectAPICore
//
//  P0 直连(code review P0-2 二审): "directAPI 模式下不经任何第三方服务器"这条产品承诺, 光靠一个个找 UI
//  入口加 if 判断挡不住(仓库有几十处网络调用点, 枚举清单必然会漏)。这个 URLProtocol 是网络层最后一道闸:
//  拦截 directAPI 模式下任何打向已知 ccServer host 的请求, 在离开设备前就失败。
//
//  二审 fresh Foundation 对照 probe 坐实: 全局 `URLProtocol.registerClass` 只覆盖 `URLSession.shared`,
//  覆盖不了显式构造的 `URLSession(configuration:)`(`URLSessionConfiguration.default` 不会自动带上
//  已注册的自定义 protocol class)。app 项目里 ChatNetworkClient/ChatViewModel/PushTokenManager/
//  GroupNetworkClient 等大量自建 session 若不显式注入, 网络层这道闸对它们形同虚设。
//
//  修法: 唯一 session/configuration 工厂 `ccGuarded(_:)`, 把本 protocol class 显式插进
//  `protocolClasses` 首位——所有自建 session 都必须经这个工厂, 不再各自手写 `URLSessionConfiguration.default`。
//  纯逻辑抽在 DirectAPICore(不含任何 app 专属状态), app 侧只在启动时注入 `isActiveProvider` /
//  `guardedHostsProvider` 两个闭包(CcServerConfig/DirectAPIConfig 是 app 专属状态, 天然不该进这个包),
//  真正的拦截 + 工厂机制在这里用 `swift test` 可复跑验证。
//

import Foundation

public final class DirectAPIServerGuardProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _isActiveProvider: () -> Bool = { false }
    nonisolated(unsafe) private static var _guardedHostsProvider: () -> Set<String> = { [] }

    /// app 侧注入: 当前是否 directAPI 模式(gate 只在这个模式下生效)。
    public static var isActiveProvider: () -> Bool {
        get { lock.withLock { _isActiveProvider } }
        set { lock.withLock { _isActiveProvider = newValue } }
    }

    /// app 侧注入: 当前已知的 ccServer host 集合(活跃 endpoint + 用户配置过的全部 endpoint 列表)。
    public static var guardedHostsProvider: () -> Set<String> {
        get { lock.withLock { _guardedHostsProvider } }
        set { lock.withLock { _guardedHostsProvider = newValue } }
    }

    public static func register() {
        URLProtocol.registerClass(DirectAPIServerGuardProtocol.self)
    }

    /// 唯一 session/configuration 工厂: 任何自建 session 都必须经这个, 把 guard 显式插入
    /// `protocolClasses` 首位——global `registerClass` 只覆盖 `URLSession.shared`, 覆盖不到
    /// 显式 configuration(fresh Foundation 对照 probe 坐实, 见 ServerGuardTests)。
    public static func ccGuarded(_ configuration: URLSessionConfiguration = .default) -> URLSessionConfiguration {
        configuration.protocolClasses = [Self.self] + (configuration.protocolClasses ?? [])
        return configuration
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        guard isActiveProvider() else { return false }
        guard let host = request.url?.host, !host.isEmpty else { return false }
        return guardedHostsProvider().contains(host)
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let error = NSError(
            domain: "DirectAPIServerGuard",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "directAPI 模式下已禁止访问 ccServer(不经任何第三方服务器)"]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    override public func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

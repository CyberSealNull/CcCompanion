//
//  DirectAPIServerGuard.swift
//  CcCompanion
//
//  P0 直连(code review P0-2 二审回炉): "directAPI 模式下不经任何第三方服务器"这条产品承诺, 光靠一个个找
//  UI 入口加 if 判断挡不住(这仓库有几十处网络调用点, 枚举清单必然会漏, 见 result 文档的完整调用点清单)。
//  这个 URLProtocol 是网络层最后一道闸: 拦截 directAPI 模式下任何打向 CcServerConfig 已知 host 的
//  请求, 在离开设备前就失败——不管是漏 gate 的 UI 入口、后台轮询、还是未来新加的调用点, 结构上都
//  拦得住, 不依赖"记得改每一处"。
//
//  二审 fresh Foundation 对照 probe 坐实: global `URLProtocol.registerClass` 只覆盖 `URLSession.shared`,
//  覆盖不了 ChatNetworkClient/ChatViewModel/PushTokenManager/GroupNetworkClient 等大量自建
//  `URLSession(configuration:)`。真正的拦截 class + `ccGuarded()` 工厂已经搬进 DirectAPICore(纯逻辑,
//  `swift test` 可复跑验证, 见 ServerGuardTests) —— 这个文件只剩 app 专属状态(CcServerConfig 的 host
//  列表 / DirectAPIConfig.isActive)的注入, 不再重复定义拦截逻辑本身。
//

import Foundation
import DirectAPICore

enum DirectAPIServerGuardWiring {
    static func install() {
        DirectAPIServerGuardProtocol.isActiveProvider = { DirectAPIConfig.isActive }
        // 当前已知的 ccServer host 集合: 活跃 endpoint + 用户配置过的全部 endpoint 列表(哪怕当前没选中,
        // 用户之前配过的地址也不该在 directAPI 模式下被打).
        DirectAPIServerGuardProtocol.guardedHostsProvider = {
            var hosts: Set<String> = []
            if let h = CcServerConfig.serverURL.host { hosts.insert(h) }
            for ep in CcServerConfig.endpoints {
                if let h = URL(string: ep.url)?.host { hosts.insert(h) }
            }
            return hosts
        }
        DirectAPIServerGuardProtocol.register()
    }
}

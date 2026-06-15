import Foundation

// 微信主题 v2.7 引入的 flavor 分流层.
// 这个私版 repo 整体编译带 OPIA_FLAVOR (定义在 project.pbxproj 的 SWIFT_ACTIVE_COMPILATION_CONDITIONS);
// 阶段二 port 到公开 repo 时, 公开 target 不定义 OPIA_FLAVOR, 自动走中性默认.
// 默认资源 (头像 / 昵称 / 拍一拍文案) 一律走这里, 不在业务代码里写死, 避免阶段二返工.
//
// 红线: 情头真人脸图绝不进公开 flavor, 绝不 commit 进 git. 见 defaultWechatAvatarAssetName.
enum FlavorConfig {

    /// 是否私版 (带情头 / 私密味). 公开版为 false.
    static var isPrivate: Bool {
        #if OPIA_FLAVOR
        return true
        #else
        return false
        #endif
    }

    /// 微信主题 AI 默认昵称, 仅作 server /status/wechat_nick 拉取前 / 拉取失败时的本地兜底.
    /// 真实昵称由 server 提供 (私有部署 server 默认带身份). 源码不硬编码私名, 兜底走中性常量.
    static var defaultWechatNick: String {
        #if OPIA_FLAVOR
        return CcDefaultAIName
        #else
        return "AI"
        #endif
    }

    /// 反向拍一拍默认后缀 (用户未在设置里自定义时). 私版可带味, 公开版通用.
    static var defaultPatPatSuffix: String {
        #if OPIA_FLAVOR
        return ""
        #else
        return ""
        #endif
    }

    /// 微信主题默认头像资源名 (bundle 内 asset / 文件名). 私版情头, 公开版 nil → 走中性占位.
    ///
    /// 情头真人脸图 (私有部署者本人 + AI 形象的真实头像) 绝不 commit 进 git / 绝不进公开 flavor.
    /// 当前回退 nil: 私版也先走现有 emoji / SF Symbol 默认, 不影响功能也不泄漏人脸.
    /// 情头真要做默认头像, 由私有部署者本地把图落进 bundle (git 忽略) 后在此填资源名, 不进版本库.
    static func defaultWechatAvatarAssetName(isAI: Bool) -> String? {
        return nil
    }
}

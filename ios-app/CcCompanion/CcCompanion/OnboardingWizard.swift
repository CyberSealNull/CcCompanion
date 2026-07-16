import SwiftUI
import DirectAPICore
#if canImport(UIKit)
import UIKit
#endif

struct OnboardingWizard: View {
    @AppStorage("cc_onboarding_completed") private var onboardingCompleted: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var step: Int = 0
    @State private var serverURLInput: String = ""
    @State private var sharedSecretInput: String = ""
    @State private var tailscaleDetectMessage: String = ""
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var connectionError: String = ""
    // Phase A — identity setup drafts (only persisted when user taps "下一步" / "进入 chat", not on 跳过)
    @State private var aiAvatarDraft: String = ""
    @State private var aiNameDraft: String = ""
    @State private var userAvatarDraft: String = ""
    @State private var userNameDraft: String = ""
    // P0 直连: 门 B persona 草稿(顺手在 AIIdentity 步填), 门 A 路径上这个值从不被读.
    @State private var directAPIPersonaDraft: String = DirectAPIConfig.persona
    // P0 直连: 门 A/门 B 分岔标记. 只影响 step 5(AIIdentity) 是否带 personaDraft, 不改 步 0-4/6 任何行为.
    @State private var viaDirectAPI: Bool = false

    // Phase B (2026-05-11) — wizard 流: welcome / Claude setup / serverURL / secret / connection / AI identity / user identity
    // spec 写 totalSteps 6→8 但 step 命名 (step 0=welcome, step 2=serverURL) 暗示替换旧 welcome + 总共 7 步.
    // 为 UX 清爽 (避免两个 welcome 屏) 走 7 步实施, 见 result md 解释.
    private let totalSteps: Int = 7  // 0:welcome 1:claudeSetup 2:server 3:secret 4:connection 5:AI identity 6:user identity
    // P0 直连: 门 A/门 B 分岔步骤, 用 7 以外的数字避免跟上面 0-6 任何 step 语义冲突/被 stepDots 误画.
    // step 10 = 选门, step 11 = 门 B provider/key/测试连通. 门 A 选择后落回 step 1, 原 1→6 流程逐字节不变.
    private static let stepChoosePath = 10
    private static let stepDirectAPISetup = 11

    enum ConnectionStatus { case idle, testing, success, failed }

    var body: some View {
        ZStack {
            Color.ccBg.ignoresSafeArea()
            VStack(spacing: 0) {
                // P0 直连: 选门/门 B 设置步不在 0..<totalSteps 范围内(故意, 保门 A 1-6 步号不变), 这两步期间
                // 隐掉点阵(错位的点阵比没有更误导), 回到门 A/门 B 各自主流程后点阵照常.
                if step != Self.stepChoosePath && step != Self.stepDirectAPISetup {
                    stepDots
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                }

                ZStack {
                    if step == 0 {
                        // P0 直连: Welcome 之后先落选门步(10), 门 A 选择后落回 step 1 原路不变.
                        WizardStepWelcome(onContinue: { withAnimation { step = Self.stepChoosePath } })
                            .transition(.opacity)
                    }
                    if step == Self.stepChoosePath {
                        WizardStepChoosePath(
                            onChooseCcServer: { withAnimation { step = 1 } },
                            onChooseDirectAPI: { withAnimation { step = Self.stepDirectAPISetup } }
                        )
                        .transition(.opacity)
                    }
                    if step == Self.stepDirectAPISetup {
                        WizardStepDirectAPISetup(
                            onNext: { provider, baseURL, model, key in
                                persistDirectAPISetup(provider: provider, baseURL: baseURL, model: model, key: key)
                                viaDirectAPI = true
                                withAnimation { step = 5 }
                            },
                            onBack: { withAnimation { step = Self.stepChoosePath } }
                        )
                        .transition(.opacity)
                    }
                    if step == 1 {
                        WizardStepClaudeSetup(onContinue: { withAnimation { step = 2 } })
                            .transition(.opacity)
                    }
                    if step == 2 { stepServerURL.transition(.opacity) }
                    if step == 3 { stepSecret.transition(.opacity) }
                    if step == 4 { stepConnection.transition(.opacity) }
                    if step == 5 {
                        WizardStepAIIdentity(
                            aiAvatarDraft: $aiAvatarDraft,
                            aiNameDraft: $aiNameDraft,
                            personaDraft: viaDirectAPI ? $directAPIPersonaDraft : nil,
                            onNext: { saveAIIdentityIfDirty(); withAnimation { step = 6 } },
                            onSkip: { withAnimation { step = 6 } }
                        )
                        .transition(.opacity)
                    }
                    if step == 6 {
                        WizardStepUserIdentity(
                            userAvatarDraft: $userAvatarDraft,
                            userNameDraft: $userNameDraft,
                            onDone: { saveUserIdentityIfDirty(); completeOnboarding() },
                            onSkip: { completeOnboarding() }
                        )
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Step indicator dots

    private var stepDots: some View {
        HStack(spacing: 10) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.ccAccent : Color.ccTextDim.opacity(0.25))
                    .frame(width: i == step ? 22 : 8, height: 8)
                    .animation(.spring(response: 0.35), value: step)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var stepWelcome: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("🦀")
                .font(.system(size: 80))
                .frame(width: 100, height: 100)
                .padding(.bottom, 20)
            Text("欢迎来到 CcCompanion")
                .font(.ccSerifAdaptive(size: 24, weight: .bold))
                .foregroundStyle(Color.ccText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Text("把 cc 装进口袋")
                .font(.ccSerifAdaptive(size: 16))
                .foregroundStyle(Color.ccTextDim)
                .padding(.bottom, 32)
            VStack(alignment: .leading, spacing: 6) {
                Label("需要先在自己的 Mac 上运行 push.py 服务端", systemImage: "desktopcomputer")
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccText)
                Label("通过它与 Claude Code 通信，收发消息", systemImage: "arrow.left.arrow.right")
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccText)
                Label("整个配置只需要一分钟", systemImage: "clock")
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccText)
            }
            .padding(16)
            .background(Color.ccCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer()
            actionButton(label: "开始配置") {
                withAnimation { step = 1 }
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Step 2: Server URL

    private var stepServerURL: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundStyle(Color.ccAccent)
                .padding(.bottom, 16)
            Text("Server 地址")
                .font(.ccSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.ccText)
                .padding(.bottom, 6)
            Text("Mac 上跑 push.py 的 Tailscale HTTPS 入口")
                .font(.ccSerifAdaptive(size: 14))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            TextField("https://<machine>.<tailnet>.ts.net", text: $serverURLInput)
                .font(.ccSerifAdaptive(size: 15))
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isValidURL(serverURLInput) ? Color.ccAccent.opacity(0.5) : Color.clear, lineWidth: 1)
                )
            Button {
                detectTailscaleEndpoint()
            } label: {
                Label("Detect Tailscale", systemImage: "network.badge.shield.half.filled")
                    .font(.ccSerifAdaptive(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.ccCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.top, 10)

            if !tailscaleDetectMessage.isEmpty {
                Text(tailscaleDetectMessage)
                    .font(.ccSerifAdaptive(size: 12))
                    .foregroundStyle(Color.ccTextDim)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }

            Text("Mac 端运行 onboard.sh 后复制 /tmp/ccc-apns-https-endpoint 里的地址。如果连不上，检查 Tailscale HTTPS certificates: https://login.tailscale.com/admin/dns")
                .font(.ccSerifAdaptive(size: 12))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer()
            actionButton(label: "下一步", disabled: !isValidURL(serverURLInput)) {
                withAnimation { step = 3 }
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Step 3: SharedSecret

    private var stepSecret: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.ccAccent)
                .padding(.bottom, 16)
            Text("鉴权密钥")
                .font(.ccSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.ccText)
                .padding(.bottom, 6)
            Text("server 端 config.toml 里的 shared_secret")
                .font(.ccSerifAdaptive(size: 14))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            SecureField("shared_secret", text: $sharedSecretInput)
                .font(.ccSerifAdaptive(size: 15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(!sharedSecretInput.isEmpty ? Color.ccAccent.opacity(0.5) : Color.clear, lineWidth: 1)
                )
            Spacer()
            actionButton(label: "下一步", disabled: sharedSecretInput.isEmpty) {
                connectionStatus = .idle
                connectionError = ""
                withAnimation { step = 4 }
                Task { await testConnection() }
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Step 4: Test connection

    private var stepConnection: some View {
        VStack(spacing: 0) {
            Spacer()
            switch connectionStatus {
            case .idle, .testing:
                ProgressView()
                    .scaleEffect(1.6)
                    .tint(Color.ccAccent)
                    .padding(.bottom, 20)
                Text("正在连接…")
                    .font(.ccSerifAdaptive(size: 17))
                    .foregroundStyle(Color.ccTextDim)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .padding(.bottom, 16)
                Text("连接成功")
                    .font(.ccSerifAdaptive(size: 22, weight: .bold))
                    .foregroundStyle(Color.ccText)
                    .padding(.bottom, 6)
                Text("已成功连接到你的 server")
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccTextDim)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
                    .padding(.bottom, 16)
                Text("连接失败")
                    .font(.ccSerifAdaptive(size: 22, weight: .bold))
                    .foregroundStyle(Color.ccText)
                    .padding(.bottom, 6)
                if !connectionError.isEmpty {
                    Text(connectionError)
                        .font(.ccSerifAdaptive(size: 13))
                        .foregroundStyle(Color.ccTextDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            Spacer()
            if connectionStatus == .success {
                // Phase A — connection 成功后顺接 AI identity setup, 不直接完成
                actionButton(label: "下一步, 设置 AI 身份") {
                    // Persist server URL + secret here (跟 phase 2.2 之前的 completeOnboarding 同 logic, 但 onboardingCompleted 不翻直到最后)
                    if let url = URL(string: serverURLInput),
                       let defaults = UserDefaults(suiteName: CcServerConfig.appGroup) {
                        defaults.set(url.absoluteString, forKey: "serverURL")
                        if !sharedSecretInput.isEmpty {
                            CcServerConfig.setSharedSecret(sharedSecretInput)
                        }
                    }
                    withAnimation { step = 5 }
                }
            } else if connectionStatus == .failed {
                actionButton(label: "返回检查地址跟密码") {
                    withAnimation { step = 2 }
                    connectionStatus = .idle
                    connectionError = ""
                }
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func actionButton(label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(disabled ? Color.ccTextDim.opacity(0.3) : Color.ccAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(disabled)
        .padding(.bottom, 36)
    }

    private func isValidURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let host = url.host,
              !host.isEmpty,
              host != "example.com",
              url.scheme == "http" || url.scheme == "https" else { return false }
        return true
    }

    private func detectTailscaleEndpoint() {
        #if canImport(UIKit)
        let pasted = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isValidURL(pasted), pasted.hasPrefix("https://"), pasted.contains(".ts.net") {
            serverURLInput = pasted
            tailscaleDetectMessage = "已从剪贴板填入 Tailscale HTTPS 地址"
        } else {
            tailscaleDetectMessage = "先在 Mac 端复制 /tmp/ccc-apns-https-endpoint 里的 https 地址，再点 Detect Tailscale"
        }
        #else
        tailscaleDetectMessage = "请手动粘贴 Mac 端 /tmp/ccc-apns-https-endpoint 里的 https 地址"
        #endif
    }

    private func testConnection() async {
        guard let baseURL = URL(string: serverURLInput) else {
            connectionError = "URL 格式错误"
            connectionStatus = .failed
            return
        }
        connectionStatus = .testing
        let url = baseURL.appendingPathComponent("health")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"  // 5-9 用户测 build 127 wizard 登不上 真因 POST /health 404 push.py /health 只 register GET
        if !sharedSecretInput.isEmpty {
            req.setValue(sharedSecretInput, forHTTPHeaderField: "X-Auth-Token")
        }
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 {
                let text = String(data: data, encoding: .utf8) ?? ""
                if text.lowercased().contains("ok") {
                    connectionStatus = .success
                    connectionError = ""
                } else {
                    connectionStatus = .failed
                    connectionError = "Server 返回 200 但响应格式异常"
                }
            } else {
                connectionStatus = .failed
                connectionError = status == -1 ? "无法连接，请检查地址" : "HTTP \(status)"
            }
        } catch {
            connectionStatus = .failed
            connectionError = error.localizedDescription
        }
    }

    private func completeOnboarding() {
        // Phase A — server URL + secret already persisted at step 3 → 4 transition.
        // Idempotent re-write here as belt-and-suspenders in case user backed up.
        if let url = URL(string: serverURLInput),
           let defaults = UserDefaults(suiteName: CcServerConfig.appGroup) {
            defaults.set(url.absoluteString, forKey: "serverURL")
            if !sharedSecretInput.isEmpty {
                CcServerConfig.setSharedSecret(sharedSecretInput)
            }
        }
        onboardingCompleted = true
        dismiss()
    }

    /// P0 直连 门 B: WizardStepDirectAPISetup 测试连通成功后落盘(跟 completeOnboarding 同一套「点下一步才写」
    /// 节奏). key 进 Keychain, 其余进 UserDefaults, 最后翻 mode — 翻 mode 放最后一步, 之前任何一步失败/用户
    /// 返回都不会让 app 半配置地卡进 directAPI 模式.
    private func persistDirectAPISetup(provider: DirectAPIProvider, baseURL: String, model: String, key: String) {
        DirectAPIConfig.provider = provider
        if provider.needsBaseURL, !baseURL.isEmpty {
            DirectAPIConfig.baseURL = baseURL
        }
        if !model.isEmpty {
            DirectAPIConfig.model = model
        }
        DirectAPIConfig.setApiKey(key)
        DirectAPIConfig.mode = .directAPI
    }

    /// Persist AI identity drafts to UserDefaults if user typed anything.
    /// 跳过 path doesn't call this so default public-build values remain.
    private func saveAIIdentityIfDirty() {
        let trimmedName = aiNameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            UserDefaults.standard.set(trimmedName, forKey: "ai_name")
            CcNameResolver.notifyChanged()
        }
        let trimmedAvatar = aiAvatarDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedAvatar.isEmpty {
            UserDefaults.standard.set(trimmedAvatar, forKey: "ai_avatar_emoji")
            CcNameResolver.notifyChanged()
        }
    }

    /// Persist user identity drafts. 跳过 = no write.
    private func saveUserIdentityIfDirty() {
        let trimmedName = userNameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            UserDefaults.standard.set(trimmedName, forKey: "user_name")
            CcNameResolver.notifyChanged()
        }
        let trimmedAvatar = userAvatarDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedAvatar.isEmpty {
            UserDefaults.standard.set(trimmedAvatar, forKey: "user_avatar_emoji")
        }
    }
}

import SwiftUI

struct OnboardingWizard: View {
    @AppStorage("opia_onboarding_completed") private var onboardingCompleted: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var step: Int = 0
    @State private var serverURLInput: String = ""
    @State private var sharedSecretInput: String = ""
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var connectionError: String = ""
    // Phase A — identity setup drafts (only persisted when user taps "下一步" / "进入 chat", not on 跳过)
    @State private var aiAvatarDraft: String = ""
    @State private var aiNameDraft: String = ""
    @State private var userAvatarDraft: String = ""
    @State private var userNameDraft: String = ""

    // Phase B (2026-05-11) — wizard 流: welcome / Claude setup / serverURL / secret / connection / AI identity / user identity
    // spec 写 totalSteps 6→8 但 step 命名 (step 0=welcome, step 2=serverURL) 暗示替换旧 welcome + 总共 7 步.
    // 为 UX 清爽 (避免两个 welcome 屏) 走 7 步实施, 见 result md 解释.
    private let totalSteps: Int = 7  // 0:welcome 1:claudeSetup 2:server 3:secret 4:connection 5:AI identity 6:user identity

    enum ConnectionStatus { case idle, testing, success, failed }

    var body: some View {
        ZStack {
            Color.opiaBg.ignoresSafeArea()
            VStack(spacing: 0) {
                stepDots
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                ZStack {
                    if step == 0 {
                        WizardStepWelcome(onContinue: { withAnimation { step = 1 } })
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
                    .fill(i == step ? Color.opiaAccent : Color.opiaTextDim.opacity(0.25))
                    .frame(width: i == step ? 22 : 8, height: 8)
                    .animation(.spring(response: 0.35), value: step)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var stepWelcome: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("clawd")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .padding(.bottom, 20)
            Text("欢迎来到 CcCompanion")
                .font(.opiaSerifAdaptive(size: 24, weight: .bold))
                .foregroundStyle(Color.opiaText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
            Text("把 cc 装进口袋")
                .font(.opiaSerifAdaptive(size: 16))
                .foregroundStyle(Color.opiaTextDim)
                .padding(.bottom, 32)
            VStack(alignment: .leading, spacing: 6) {
                Label("需要先在自己的 Mac 上运行 push.py 服务端", systemImage: "desktopcomputer")
                    .font(.opiaSerifAdaptive(size: 14))
                    .foregroundStyle(Color.opiaText)
                Label("通过它与 Claude Code 通信，收发消息", systemImage: "arrow.left.arrow.right")
                    .font(.opiaSerifAdaptive(size: 14))
                    .foregroundStyle(Color.opiaText)
                Label("整个配置只需要一分钟", systemImage: "clock")
                    .font(.opiaSerifAdaptive(size: 14))
                    .foregroundStyle(Color.opiaText)
            }
            .padding(16)
            .background(Color.opiaCard)
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
                .foregroundStyle(Color.opiaAccent)
                .padding(.bottom, 16)
            Text("Server 地址")
                .font(.opiaSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.opiaText)
                .padding(.bottom, 6)
            Text("Mac 上跑 push.py 的公网入口")
                .font(.opiaSerifAdaptive(size: 14))
                .foregroundStyle(Color.opiaTextDim)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            TextField("http://...", text: $serverURLInput)
                .font(.opiaSerifAdaptive(size: 15))
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(Color.opiaCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isValidURL(serverURLInput) ? Color.opiaAccent.opacity(0.5) : Color.clear, lineWidth: 1)
                )
            Text("不知道怎么架？参考 framework 文档（TBD）了解 server 部署方式")
                .font(.opiaSerifAdaptive(size: 12))
                .foregroundStyle(Color.opiaTextDim)
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
                .foregroundStyle(Color.opiaAccent)
                .padding(.bottom, 16)
            Text("鉴权密钥")
                .font(.opiaSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.opiaText)
                .padding(.bottom, 6)
            Text("server 端 config.toml 里的 shared_secret")
                .font(.opiaSerifAdaptive(size: 14))
                .foregroundStyle(Color.opiaTextDim)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            SecureField("shared_secret", text: $sharedSecretInput)
                .font(.opiaSerifAdaptive(size: 15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(Color.opiaCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(!sharedSecretInput.isEmpty ? Color.opiaAccent.opacity(0.5) : Color.clear, lineWidth: 1)
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
                    .tint(Color.opiaAccent)
                    .padding(.bottom, 20)
                Text("正在连接…")
                    .font(.opiaSerifAdaptive(size: 17))
                    .foregroundStyle(Color.opiaTextDim)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .padding(.bottom, 16)
                Text("连接成功")
                    .font(.opiaSerifAdaptive(size: 22, weight: .bold))
                    .foregroundStyle(Color.opiaText)
                    .padding(.bottom, 6)
                Text("已成功连接到你的 server")
                    .font(.opiaSerifAdaptive(size: 14))
                    .foregroundStyle(Color.opiaTextDim)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
                    .padding(.bottom, 16)
                Text("连接失败")
                    .font(.opiaSerifAdaptive(size: 22, weight: .bold))
                    .foregroundStyle(Color.opiaText)
                    .padding(.bottom, 6)
                if !connectionError.isEmpty {
                    Text(connectionError)
                        .font(.opiaSerifAdaptive(size: 13))
                        .foregroundStyle(Color.opiaTextDim)
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
                       let defaults = UserDefaults(suiteName: OpiaServerConfig.appGroup) {
                        defaults.set(url.absoluteString, forKey: "serverURL")
                        if !sharedSecretInput.isEmpty {
                            defaults.set(sharedSecretInput, forKey: "sharedSecret")
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
                .font(.opiaSerifAdaptive(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(disabled ? Color.opiaTextDim.opacity(0.3) : Color.opiaAccent)
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
           let defaults = UserDefaults(suiteName: OpiaServerConfig.appGroup) {
            defaults.set(url.absoluteString, forKey: "serverURL")
            if !sharedSecretInput.isEmpty {
                defaults.set(sharedSecretInput, forKey: "sharedSecret")
            }
        }
        onboardingCompleted = true
        dismiss()
    }

    /// Persist AI identity drafts to UserDefaults if user typed anything.
    /// 跳过 path doesn't call this so default public-build values remain.
    private func saveAIIdentityIfDirty() {
        let trimmedName = aiNameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            UserDefaults.standard.set(trimmedName, forKey: "ai_name")
            OpiaNameResolver.notifyChanged()
        }
        let trimmedAvatar = aiAvatarDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedAvatar.isEmpty {
            UserDefaults.standard.set(trimmedAvatar, forKey: "ai_avatar_emoji")
            OpiaNameResolver.notifyChanged()
        }
    }

    /// Persist user identity drafts. 跳过 = no write.
    private func saveUserIdentityIfDirty() {
        let trimmedName = userNameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            UserDefaults.standard.set(trimmedName, forKey: "user_name")
            OpiaNameResolver.notifyChanged()
        }
        let trimmedAvatar = userAvatarDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedAvatar.isEmpty {
            UserDefaults.standard.set(trimmedAvatar, forKey: "user_avatar_emoji")
        }
    }
}

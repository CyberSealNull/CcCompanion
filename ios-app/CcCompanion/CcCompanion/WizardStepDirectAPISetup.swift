//
//  WizardStepDirectAPISetup.swift
//  CcCompanion
//
//  P0 直连 onboarding 门 B — Step: provider 选择 + key 填写 + 测试连通.
//  测试连通成功才能下一步(逼用户先确认 key 真能用, 呼应 stepConnection 的既有节奏).
//

import SwiftUI
import DirectAPICore

struct WizardStepDirectAPISetup: View {
    /// 测试成功后回调, 把选好的 provider/baseURL/model/key 交给父视图持久化(跟其它 wizard 步骤一样,
    /// 「下一步」被点时才落盘, 不在输入过程中偷偷写 Keychain).
    let onNext: (DirectAPIProvider, String, String, String) -> Void
    let onBack: () -> Void

    @State private var provider: DirectAPIProvider = .anthropic
    @State private var baseURL: String = DirectAPIConfig.defaultOpenAICompatBaseURL
    @State private var model: String = DirectAPIProvider.anthropic.defaultModel
    @State private var apiKey: String = ""
    @State private var testStatus: ConnectionTestStatus = .idle
    @State private var testError: String = ""

    enum ConnectionTestStatus: Equatable { case idle, testing, success, failed }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 8)

            Text("先快速体验")
                .font(.ccSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.ccText)
                .padding(.bottom, 6)
            Text("填一个 API key 就能直接聊, 不用装 Claude Code、不用搭 server。key 只存本机 Keychain, 直连官方 API, 不经任何第三方服务器。")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 12)
                .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 12) {
                    Picker("", selection: $provider) {
                        ForEach(DirectAPIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: provider) { _, newValue in
                        model = newValue.defaultModel
                        testStatus = .idle
                    }

                    if provider == .openAICompat {
                        labeledField(label: "baseURL", text: $baseURL, placeholder: DirectAPIConfig.defaultOpenAICompatBaseURL, keyboard: .URL)
                    }
                    labeledField(label: "model", text: $model, placeholder: provider.defaultModel)
                    labeledSecureField(label: "API key", text: $apiKey, placeholder: "sk-…")

                    statusView
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task { await testConnection() }
                } label: {
                    Text(testStatus == .testing ? "测试中…" : "测试连通")
                        .font(.ccSerifAdaptive(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ccAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.ccCard)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(trimmedKey.isEmpty || testStatus == .testing)

                Button {
                    onNext(provider, provider == .openAICompat ? baseURL : "", model, trimmedKey)
                } label: {
                    Text("下一步")
                        .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(testStatus == .success ? Color.ccAccent : Color.ccTextDim.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(testStatus != .success)

                Button(action: onBack) {
                    Text("返回")
                        .font(.ccSerifAdaptive(size: 14))
                        .foregroundStyle(Color.ccTextDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var statusView: some View {
        switch testStatus {
        case .idle, .testing:
            EmptyView()
        case .success:
            Label("连接成功", systemImage: "checkmark.circle.fill")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(.green)
        case .failed:
            Label(testError, systemImage: "xmark.circle.fill")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func labeledField(label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                .foregroundStyle(Color.ccTextDim)
            TextField(placeholder, text: text)
                .font(.system(.body, design: .monospaced))
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: text.wrappedValue) { _, _ in testStatus = .idle }
        }
    }

    @ViewBuilder
    private func labeledSecureField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                .foregroundStyle(Color.ccTextDim)
            SecureField(placeholder, text: text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: text.wrappedValue) { _, _ in testStatus = .idle }
        }
    }

    private func testConnection() async {
        testStatus = .testing
        let result = await DirectAPIClient.testConnection(
            provider: provider,
            baseURL: provider == .openAICompat ? baseURL : "",
            model: model,
            apiKey: trimmedKey
        )
        switch result {
        case .success:
            testStatus = .success
        case .failure(let err):
            testStatus = .failed
            testError = err.errorDescription ?? "连接失败"
        }
    }
}

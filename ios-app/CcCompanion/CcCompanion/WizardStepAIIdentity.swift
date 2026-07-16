//
//  WizardStepAIIdentity.swift
//  CcCompanion
//
//  CcCompanion onboarding wizard — Step: AI 身份 (头像 + 名字 + 跳过).
//  Phase C — image picker + circular crop (替代 emoji TextField).
//

import SwiftUI
import UIKit

struct WizardStepAIIdentity: View {
    @Binding var aiAvatarDraft: String        // legacy emoji storage (Phase A) — Phase C ignored for image path
    @Binding var aiNameDraft: String
    // P0 直连: 门 B 顺手填 persona, nil = 门 A(不渲染这个 field, body 逐字节不变). 门 B 传真 binding.
    var personaDraft: Binding<String>? = nil
    let onNext: () -> Void
    let onSkip: () -> Void

    @State private var pickerPresented = false
    @State private var pickedImage: UIImage? = nil
    @State private var cropPresented = false
    @State private var savedImage: UIImage? = nil  // 已 crop + 保存

    private static let avatarFilename = "cccAvatarAI.png"

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("给你的 AI 一个样子")
                .font(.ccSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.ccText)
                .padding(.bottom, 6)
            Text("点击头像选图, 起个名字. 跳过会用默认 Claude 跟小螃蟹")
                .font(.ccSerifAdaptive(size: 13))
                .foregroundStyle(Color.ccTextDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

            // Avatar tap area
            Button {
                pickerPresented = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.ccCard)
                        .frame(width: 96, height: 96)
                    if let img = savedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    } else {
                        Text("🦀")
                            .font(.system(size: 48))
                            .frame(width: 64, height: 64)
                    }
                    // Camera badge bottom-right
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.ccAccent)
                        .clipShape(Circle())
                        .offset(x: 32, y: 32)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)

            TextField("Claude", text: $aiNameDraft)
                .font(.ccSerifAdaptive(size: 16))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(aiNameDraft.isEmpty ? Color.clear : Color.ccAccent.opacity(0.5), lineWidth: 1)
                )
                .padding(.horizontal, 40)

            if let personaDraft {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI 人格 (可选, 跳过用默认)")
                        .font(.ccSerifAdaptive(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ccTextDim)
                    TextEditor(text: personaDraft)
                        .font(.system(size: 13))
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.ccCard)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
            }

            Spacer()

            VStack(spacing: 10) {
                Button(action: { saveAvatarIfPicked(); onNext() }) {
                    Text("下一步")
                        .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.ccAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button(action: onSkip) {
                    Text("跳过, 用默认")
                        .font(.ccSerifAdaptive(size: 14))
                        .foregroundStyle(Color.ccTextDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                Text("稍后可在设置页更改")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccTextDim.opacity(0.7))
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .sheet(isPresented: $pickerPresented) {
            AvatarPHPicker { img in
                pickerPresented = false
                if let img {
                    pickedImage = img
                    // small delay for sheet dismissal animation before presenting crop
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        cropPresented = true
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $cropPresented) {
            if let img = pickedImage {
                AvatarCropView(
                    originalImage: img,
                    onConfirm: { cropped in
                        savedImage = cropped
                        cropPresented = false
                    },
                    onCancel: { cropPresented = false }
                )
            }
        }
        .onAppear {
            // Restore on view recreate (back-nav etc)
            if savedImage == nil {
                savedImage = AvatarDiskStore.load(filename: Self.avatarFilename)
            }
        }
    }

    /// Write picked+cropped image to documents dir + UserDefaults path. 跳过 = no write.
    private func saveAvatarIfPicked() {
        let trimmedName = aiNameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            UserDefaults.standard.set(trimmedName, forKey: "ai_name")
            CcNameResolver.notifyChanged()
        }
        if let img = savedImage,
           let filename = AvatarDiskStore.save(img, filename: Self.avatarFilename) {
            UserDefaults.standard.set(filename, forKey: "ai_avatar_path")
            CcNameResolver.notifyChanged()
        }
        // P0 直连 门 B: persona 留空 = 用默认模板(DirectAPIConfig.persona getter 已处理空值兜底).
        if let persona = personaDraft?.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), !persona.isEmpty {
            DirectAPIConfig.persona = persona
        }
    }
}

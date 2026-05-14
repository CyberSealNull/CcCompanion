//
//  WizardStepAIIdentity.swift
//  OpiaCompanion
//
//  CcCompanion onboarding wizard — Step: AI 身份 (头像 + 名字 + 跳过).
//  Phase C — image picker + circular crop (替代 emoji TextField).
//

import SwiftUI
import UIKit

struct WizardStepAIIdentity: View {
    @Binding var aiAvatarDraft: String        // legacy emoji storage (Phase A) — Phase C ignored for image path
    @Binding var aiNameDraft: String
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
                .font(.opiaSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.opiaText)
                .padding(.bottom, 6)
            Text("点击头像选图, 起个名字. 跳过会用默认 Claude 跟小螃蟹")
                .font(.opiaSerifAdaptive(size: 13))
                .foregroundStyle(Color.opiaTextDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

            // Avatar tap area
            Button {
                pickerPresented = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.opiaCard)
                        .frame(width: 96, height: 96)
                    if let img = savedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    } else {
                        Image("clawd")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                    }
                    // Camera badge bottom-right
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.opiaAccent)
                        .clipShape(Circle())
                        .offset(x: 32, y: 32)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)

            TextField("Claude", text: $aiNameDraft)
                .font(.opiaSerifAdaptive(size: 16))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color.opiaCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(aiNameDraft.isEmpty ? Color.clear : Color.opiaAccent.opacity(0.5), lineWidth: 1)
                )
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 10) {
                Button(action: { saveAvatarIfPicked(); onNext() }) {
                    Text("下一步")
                        .font(.opiaSerifAdaptive(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.opiaAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button(action: onSkip) {
                    Text("跳过, 用默认")
                        .font(.opiaSerifAdaptive(size: 14))
                        .foregroundStyle(Color.opiaTextDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                Text("稍后可在设置页更改")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.opiaTextDim.opacity(0.7))
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
            OpiaNameResolver.notifyChanged()
        }
        if let img = savedImage,
           let path = AvatarDiskStore.save(img, filename: Self.avatarFilename) {
            UserDefaults.standard.set(path, forKey: "ai_avatar_path")
            OpiaNameResolver.notifyChanged()
        }
    }
}

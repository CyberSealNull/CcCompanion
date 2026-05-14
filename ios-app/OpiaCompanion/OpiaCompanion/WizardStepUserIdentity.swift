//
//  WizardStepUserIdentity.swift
//  OpiaCompanion
//
//  CcCompanion onboarding wizard — Step: 用户身份 (头像 + 名字 + 跳过).
//  Phase C — image picker + circular crop (替代 emoji TextField).
//

import SwiftUI
import UIKit

struct WizardStepUserIdentity: View {
    @Binding var userAvatarDraft: String       // legacy emoji (Phase A) — Phase C ignored for image path
    @Binding var userNameDraft: String
    let onDone: () -> Void
    let onSkip: () -> Void

    @State private var pickerPresented = false
    @State private var pickedImage: UIImage? = nil
    @State private var cropPresented = false
    @State private var savedImage: UIImage? = nil

    private static let avatarFilename = "cccAvatarUser.png"

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("也告诉 AI 你是谁")
                .font(.opiaSerifAdaptive(size: 22, weight: .bold))
                .foregroundStyle(Color.opiaText)
                .padding(.bottom, 6)
            Text("点击头像选图, 起个名字. AI 看到这个头像跟名字 知道在跟谁说话")
                .font(.opiaSerifAdaptive(size: 13))
                .foregroundStyle(Color.opiaTextDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

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
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.opiaTextDim.opacity(0.5))
                    }
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

            TextField("你", text: $userNameDraft)
                .font(.opiaSerifAdaptive(size: 16))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color.opiaCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(userNameDraft.isEmpty ? Color.clear : Color.opiaAccent.opacity(0.5), lineWidth: 1)
                )
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 10) {
                Button(action: { saveAvatarIfPicked(); onDone() }) {
                    Text("进入 chat")
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
            if savedImage == nil {
                savedImage = AvatarDiskStore.load(filename: Self.avatarFilename)
            }
        }
    }

    private func saveAvatarIfPicked() {
        let trimmedName = userNameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            UserDefaults.standard.set(trimmedName, forKey: "user_name")
            OpiaNameResolver.notifyChanged()
        }
        if let img = savedImage,
           let path = AvatarDiskStore.save(img, filename: Self.avatarFilename) {
            UserDefaults.standard.set(path, forKey: "user_avatar_path")
            OpiaNameResolver.notifyChanged()
        }
    }
}

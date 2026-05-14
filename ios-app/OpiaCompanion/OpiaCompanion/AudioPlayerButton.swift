//
//  AudioPlayerButton.swift
//  OpiaCompanion
//
//  Chat 内 audio attachment (TTS 龙皓晨语音) — tap 播放 / 暂停
//  v0.4 2026-04-30 加多语言切换 (zh/en/ja)
//

import SwiftUI
import AVFoundation
import Combine

@MainActor
final class AudioPlayerCoordinator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerCoordinator()

    @Published var currentURL: URL? = nil
    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0
    private var player: AVAudioPlayer? = nil
    private var timer: Timer? = nil

    func toggle(url: URL) {
        if currentURL == url, isPlaying {
            stop()
            return
        }
        play(url: url)
    }

    private func play(url: URL) {
        stop()
        currentURL = url
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.play()
                self.player = p
                self.isPlaying = true
                self.progress = 0
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self, let p = self.player else { return }
                        self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
                    }
                }
            } catch {
                self.isPlaying = false
                self.currentURL = nil
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        progress = 0
        currentURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.timer?.invalidate()
            self.timer = nil
            self.currentURL = nil
        }
    }
}

struct AudioPlayerButton: View {
    let audios: [String: URL]
    @State private var selectedLang: String = "zh"
    @ObservedObject private var coordinator = AudioPlayerCoordinator.shared

    private var availableLangs: [String] {
        ["zh", "en", "ja"].filter { audios[$0] != nil }
    }

    private var currentURL: URL? {
        audios[selectedLang] ?? audios["zh"] ?? audios.values.first
    }

    var isActive: Bool {
        guard let url = currentURL else { return false }
        return coordinator.currentURL == url && coordinator.isPlaying
    }
    var progress: Double { isActive ? coordinator.progress : 0 }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let url = currentURL { coordinator.toggle(url: url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "pause.fill" : "play.fill")
                        .font(.opiaSerifAdaptive(size: 16))
                        .foregroundStyle(.white)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 60, height: 4)
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 60 * progress, height: 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.opiaAssistant)
                .clipShape(Capsule())
            }

            if availableLangs.count > 1 {
                HStack(spacing: 2) {
                    ForEach(availableLangs, id: \.self) { lang in
                        Button {
                            let wasSelected = selectedLang == lang
                            selectedLang = lang
                            if let url = audios[lang] {
                                if wasSelected {
                                    coordinator.toggle(url: url)
                                } else {
                                    coordinator.stop()
                                    coordinator.toggle(url: url)
                                }
                            }
                        } label: {
                            Text(langLabel(lang))
                                .font(.caption2.bold())
                                .foregroundStyle(selectedLang == lang ? .white : .white.opacity(0.5))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    selectedLang == lang
                                    ? Color.opiaAssistant.opacity(0.8)
                                    : Color.opiaAssistant.opacity(0.3)
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .onAppear {
            if !availableLangs.contains(selectedLang), let first = availableLangs.first {
                selectedLang = first
            }
        }
    }

    private func langLabel(_ lang: String) -> String {
        switch lang {
        case "zh": return "中"
        case "en": return "EN"
        case "ja": return "日"
        default: return lang.uppercased()
        }
    }
}

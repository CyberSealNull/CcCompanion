//
//  SpeechRecognizer.swift
//  OpiaCompanion
//
//  v0.5 语音转文字 — iOS 原生 SFSpeechRecognizer 实时转 不依赖 server Whisper
//
//  Info.plist 必须加:
//    NSSpeechRecognitionUsageDescription = "用语音跟 Opia 说话"
//    NSMicrophoneUsageDescription = "录音转文字"
//

import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var lastError: String? = nil

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init() {
        // 默认中文 想用别的 locale 改这里 (eg "en-US")
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        // 申请权限
        let speechAuth = await requestSpeechAuth()
        guard speechAuth == .authorized else {
            self.lastError = "语音识别没权限 设置 → 隐私 → 语音识别"
            return
        }
        let micAuth = await requestMicAuth()
        guard micAuth else {
            self.lastError = "麦克风没权限 设置 → 隐私 → 麦克风"
            return
        }

        guard let recognizer = recognizer, recognizer.isAvailable else {
            self.lastError = "语音识别不可用"
            return
        }

        // 设置 audio session — iOS 18 用最简 .record + .default 兼容性最好
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            // 强制走默认 builtin mic (避免 stuck 在 stale ble device)
            if let builtin = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtin)
            }
        } catch {
            self.lastError = "audio session 失败: \(error.localizedDescription)"
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            req.addsPunctuation = true
        }
        self.request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            self.lastError = "录音启动失败: \(error.localizedDescription)"
            return
        }

        self.transcript = ""
        self.isRecording = true
        self.lastError = nil

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.cleanup()
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        task?.finish()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        cleanup()
    }

    private func cleanup() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechAuth() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private func requestMicAuth() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }
}

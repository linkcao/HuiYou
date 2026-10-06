import AVFoundation
import Speech
import SwiftUI

/// 语音输入：SFSpeechRecognizer + AVAudioEngine 实时转写为文字
@MainActor
final class SpeechInput: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    /// 实时转写结果（每帧更新）
    @Published private(set) var currentText = ""

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    /// 停止/识别完成后回调最终文本
    var onFinish: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }

        // 双权限：录音 + 语音识别
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] micOK in
            guard let self else { return }
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard let self else { return }
                Task { @MainActor in
                    guard micOK, status == .authorized else {
                        self.onError?("需要麦克风和语音识别权限，请到 系统设置→洄游 里开启")
                        return
                    }
                    self.beginRecording()
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        request?.endAudio() // 让识别任务自然收尾（拿到最终结果）
        teardownAudio()
        isRecording = false
    }

    // MARK: - 内部

    private func beginRecording() {
        do {
            currentText = ""
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.currentText = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        let text = self.currentText
                        self.stopInternal()
                        if !text.isEmpty { self.onFinish?(text) }
                    }
                }
            }
        } catch {
            stopInternal()
            onError?("录音启动失败：\(error.localizedDescription)")
        }
    }

    /// 识别任务自然结束（isFinal / error）时走的清理
    private func stopInternal() {
        teardownAudio()
        isRecording = false
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }
}

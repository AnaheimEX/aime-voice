import AIMEVoice
import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum VoiceModelTestKind: String { case speech, polish, decision }

/// Each button calls the selected service with a fixed, non-personal test sample.
struct VoiceModelTestControls: View {
    @Environment(\.voiceSettingsStyle) private var style
    let settings: VoiceSettings
    let kind: VoiceModelTestKind
    @State private var message: String?
    @State private var recoveryURL: URL?
    @State private var failed = false
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var recognition: VoiceRecognitionSession?
    // Compare values: JSON object key order is unstable and used to cancel every test.
    private var configuration: VoiceSettings { settings }
    private var configured: Bool {
        switch kind {
        case .speech:
            switch settings.speechBackend {
            case .local: settings.localSpeechModel.isAvailable && settings.localSpeechModel.isDownloaded
            case .apple: true
            case .cloud: settings.asr.isConfigured
            case .interfaze: !settings.interfazeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .polish: settings.llm.isConfigured
        case .decision: settings.decision.isConfigured
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(busy ? "取消测试" : (kind == .speech ? "测试识别" : "测试模型连接")) {
                    if busy { cancel(); message = "测试已取消" } else { run() }
                }.buttonStyle(.bordered)
                    .accessibilityIdentifier("voice-model-test-\(kind.rawValue)")
                if busy { ProgressView().controlSize(.small) }
                if let recoveryURL {
                    Button("打开系统设置") { NSWorkspace.shared.open(recoveryURL) }.buttonStyle(.borderless)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(failed ? style.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("voice-model-test-result-\(kind.rawValue)")
            }
        }
        .onChange(of: configuration) { cancel() }
        .onDisappear { cancel() }
    }

    private func cancel() {
        operationID = UUID()
        operation?.cancel(); operation = nil
        recognition?.cancel(); recognition = nil
        busy = false; failed = false; message = nil; recoveryURL = nil
    }

    private func run() {
        cancel()
        guard configured else {
            failed = true
            message = kind == .speech ? "测试失败：请先下载本地模型或填写 Interfaze API Key" : "测试失败：请选择服务并补全所需模型和凭据"
            return
        }
        let id = operationID
        let requested = settings
        busy = true
        message = "正在调用当前模型，请稍候…"
        operation = Task { @MainActor in
            defer {
                if operationID == id {
                    busy = false
                    recognition?.cancel(); recognition = nil
                }
            }
            do {
                let resultMessage: String
                switch kind {
                case .speech:
                    let timing = try await testSpeech(settings: requested)
                    func value(_ milliseconds: Int?) -> String { milliseconds.map { "\($0) ms" } ?? "无中间结果" }
                    let reuse = timing.appleRecognizerReused.map { $0 ? " · 复用识别器" : " · 新建识别器" } ?? ""
                    resultMessage = "识别成功 · 测试音频总耗时 \(value(timing.totalMilliseconds))\(reuse)\n"
                        + "准备 \(value(timing.prepareMilliseconds)) · 首字 \(value(timing.firstTextMilliseconds)) · 队列排空 \(value(timing.drainMilliseconds)) · 最终收尾 \(value(timing.finalizeMilliseconds))"
                case .decision:
                    let result = try await VoiceProcessor().testDecision(text: "你好，语音测试", settings: requested)
                    resultMessage = "连接成功：决策模型响应符合协议 · \(result.elapsedMilliseconds) ms\n"
                        + (result.meetsRuntimeBudget ? "耗时符合 \(result.budgetMilliseconds) ms 预算" : "耗时超过 \(result.budgetMilliseconds) ms，实际使用时可能赶不上加速")
                case .polish:
                    let result = try await VoiceProcessor().testPolish(text: "你好", settings: requested)
                    resultMessage = "连接成功：文字模型已返回有效响应 · \(result.elapsedMilliseconds) ms"
                }
                guard operationID == id, !Task.isCancelled else { return }
                message = resultMessage
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                failed = true
                message = "测试失败：\(error.localizedDescription)"
                recoveryURL = (error as? AppleSpeechRecognitionFailure)?.settingsURL
            }
        }
    }

    @MainActor
    private func testSpeech(settings: VoiceSettings) async throws -> VoiceRecognitionTiming {
        guard let url = Bundle.module.url(forResource: "VoiceConnectionTest", withExtension: "wav") else {
            throw TestError.missingAudio
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.length > 0, file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TestError.missingAudio
        }
        try file.read(into: buffer)
        guard let samples = buffer.int16ChannelData?[0] else { throw TestError.missingAudio }
        let pcm = Data(bytes: samples, count: Int(buffer.frameLength) * 2)
        let audio = RecordedAudio(wav: try Data(contentsOf: url), duration: Double(file.length) / 16_000)
        let session = VoiceRecognitionSession(settings: settings, onPartial: { _ in })
        recognition = session
        try await session.start()
        try Task.checkCancellation()
        session.append(pcm)
        let result = try await session.finish(audio)
        try Task.checkCancellation()
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TestError.emptyResult }
        return session.timing
    }

    private enum TestError: LocalizedError {
        case missingAudio, emptyResult
        var errorDescription: String? {
            switch self {
            case .missingAudio: "内置测试音频缺失或损坏，请重新安装应用"
            case .emptyResult: "识别服务未返回有效文字，请检查当前模型或系统听写语言资源"
            }
        }
    }
}

public import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation

/// Keep Apple's service error codes instead of disguising local failures as network errors.
public struct AppleSpeechRecognitionFailure: LocalizedError, Sendable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }

    public var settingsURL: URL? {
        switch (domain, code) {
        case ("kLSRErrorDomain", 201), ("kLSRErrorDomain", 102):
            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        case ("kAFAssistantErrorDomain", 1700):
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        default: nil
        }
    }

    public var errorDescription: String? {
        switch (domain, code) {
        case ("kLSRErrorDomain", 201):
            "macOS系统听写已关闭。请在系统设置 > 键盘 > 听写中开启，再重试（Apple 201）"
        case ("kLSRErrorDomain", 102):
            "Apple本机识别语言资源未安装，请在系统设置 > 键盘 > 听写中添加系统语言并等待下载（Apple 102）"
        case ("kAFAssistantErrorDomain", 1700):
            "未获语音识别权限，请在系统设置 > 隐私与安全性 > 语音识别中允许当前AIME应用（Apple 1700）"
        case ("kAFAssistantErrorDomain", 1110):
            "Apple没有识别到语音，请确认录音包含清晰人声后重试（Apple 1110）"
        case ("kAFAssistantErrorDomain", 1100):
            "上一次Apple识别尚未结束，请稍后重试（Apple 1100）"
        case ("kAFAssistantErrorDomain", 1101), ("kAFAssistantErrorDomain", 1107):
            "Apple本机语音服务连接中断，请重试（Apple \(code)）"
        default:
            "Apple本机识别失败（\(domain) \(code)），请重试"
        }
    }
}

/// Uses the same Speech framework route as Type4Me, with a strict local-only gate.
@MainActor
final class AppleSpeechRecognition {
    // Keep one recognizer per process's current locale. Requests/tasks remain session-owned.
    private static var cachedRecognizer: (locale: String, value: SFSpeechRecognizer)?
    private static var cachedLocale: (preferences: [String], identifier: String)?
    private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
    private(set) var reusedRecognizer = false
    private let language: String
    private let hotwords: [String]
    private let onPartial: @Sendable (String) -> Void
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var terminal: Result<String, any Error>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false

    init(language: String, hotwords: [String] = [], onPartial: @escaping @Sendable (String) -> Void) {
        self.language = language
        self.hotwords = hotwords
        self.onPartial = onPartial
    }

    func start() async throws {
        let authorization = SFSpeechRecognizer.authorizationStatus()
        let authorized: Bool
        if authorization == .notDetermined {
            authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        } else { authorized = authorization == .authorized }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard authorized else { throw VoiceRecognitionError.permissionDenied }
        let localeID = Self.localeIdentifier(language)
        let candidate: SFSpeechRecognizer?
        if let cached = Self.cachedRecognizer, cached.locale == localeID,
           cached.value.isAvailable, cached.value.supportsOnDeviceRecognition {
            candidate = cached.value
            reusedRecognizer = true
        } else {
            candidate = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        }
        guard let recognizer = candidate, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            Self.cachedRecognizer = nil
            Self.cachedLocale = nil
            throw VoiceRecognitionError.onDeviceUnavailable
        }
        Self.cachedRecognizer = (localeID, recognizer)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = hotwords
        self.recognizer = recognizer
        self.request = request
        // Speech delivers results on its own queue; only the state update hops to MainActor.
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Only immutable Sendable values cross the framework callback boundary.
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failure = error.map { AppleSpeechRecognitionFailure(domain: ($0 as NSError).domain, code: ($0 as NSError).code) }
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled, self.terminal == nil else { return }
                if let text, !text.isEmpty { self.onPartial(text) }
                if final {
                    let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    self.complete(text.isEmpty ? .failure(VoiceTranscriptionError.emptyTranscript) : .success(text))
                } else if let failure { self.complete(.failure(failure)) }
            }
        }
    }

    func append(_ pcm: Data) throws {
        guard !cancelled else { throw CancellationError() }
        if let terminal { _ = try terminal.get(); return }
        guard let request, pcm.count.isMultiple(of: 2),
              let format = Self.pcmFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let samples = buffer.int16ChannelData?[0] else {
            throw VoiceRecognitionError.invalidResponse
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
        pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: pcm.count))
        request.append(buffer)
    }

    func finish() async throws -> String {
        request?.endAudio()
        if let terminal { return try terminal.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.complete(.failure(VoiceRecognitionError.timedOut))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() {
        cancelled = true
        complete(.failure(CancellationError()))
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
    }

    private func complete(_ result: Result<String, any Error>) {
        guard terminal == nil else { return }
        terminal = result
        if case .failure(let error) = result, !(error is CancellationError),
           Self.cachedRecognizer?.value === recognizer {
            // Failed/interrupted services must be recreated, not reused indefinitely.
            Self.cachedRecognizer = nil
            Self.cachedLocale = nil
        }
        timeout?.cancel()
        timeout = nil
        waiter?.resume(with: result)
        waiter = nil
    }

    private static func preferredLocaleIdentifier() -> String {
        // SFSpeechRecognizer requires a locale. Select the matching system language;
        // it does not expose audio-based multilingual auto-detection.
        let preferences = Locale.preferredLanguages + [Locale.current.identifier]
        if let cached = cachedLocale, cached.preferences == preferences { return cached.identifier }
        let identifier = resolvePreferredLocale(preferences)
        cachedLocale = (preferences, identifier)
        return identifier
    }

    private static func resolvePreferredLocale(_ preferences: [String]) -> String {
        let supported = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
        for identifier in preferences {
            let wanted = Locale(identifier: identifier)
            if let exact = supported.first(where: {
                $0.language.languageCode == wanted.language.languageCode &&
                $0.language.script == wanted.language.script && $0.region == wanted.region
            }) { return exact.identifier }
            if let equivalent = supported.first(where: {
                $0.language.languageCode == wanted.language.languageCode && $0.language.script == wanted.language.script
            }) { return equivalent.identifier }
        }
        return Locale.current.identifier
    }

    private static func localeIdentifier(_ language: String) -> String {
        switch language.lowercased() {
        case "", "auto": preferredLocaleIdentifier()
        case "zh", "zh-cn": "zh-CN"
        case "zh-tw": "zh-TW"
        case "en": "en-US"
        case "ja": "ja-JP"
        case "ko": "ko-KR"
        default: language
        }
    }
}

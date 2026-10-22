public import Foundation

public enum VoiceRecognitionError: LocalizedError, Sendable {
    case invalidConfiguration, permissionDenied, onDeviceUnavailable, invalidResponse,
         timedOut, recognitionFailed, serverCode(Int), speechHTTPStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "语音识别接口、资源 ID 或 API Key 配置不完整"
        case .permissionDenied: "请在系统设置的隐私与安全性中允许 AIME 语音使用语音识别"
        case .onDeviceUnavailable: "当前语言的 Apple 本机语音识别不可用，请安装系统语言资源或选择其他识别服务"
        case .invalidResponse: "语音识别服务返回了无法解析的响应"
        case .timedOut: "等待语音识别最终结果超时，请重试"
        case .recognitionFailed: "语音识别未返回有效文字，请检查录音或所选模型"
        case .speechHTTPStatus(401): "豆包语音鉴权失败（HTTP 401）：请填写豆包语音控制台的 API Key，火山方舟 API Key 不适用于此接口"
        case .speechHTTPStatus(403): "豆包语音拒绝访问（HTTP 403）：请检查语音服务密钥、所选识别服务是否开通及额度"
        case .speechHTTPStatus(let status): "豆包语音连接失败（HTTP \(status)），请检查服务连接及语音资源开通状态"
        case .serverCode(let code): "豆包语音识别请求失败（服务代码 \(code)），请检查 API Key、资源开通状态和额度"
        }
    }
}

/// Keeps streaming providers and whole-recording backends behind one lifecycle.
/// Streaming PCM is ordered and bounded; overflow fails instead of dropping audio.
@MainActor
public final class VoiceRecognitionSession {
    private let model: LocalSpeechModel
    private let backend: VoiceSpeechBackend
    private let interfazeAPIKey: String
    private let settings: VoiceSettings
    private let onPartial: @Sendable (String) -> Void
    private let apple: AppleSpeechRecognition?
    private let volc: VolcStreamingRecognition?
    private let bailian: BailianStreamingRecognition?
    private nonisolated let pcmContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let pcmStream: AsyncThrowingStream<Data, any Error>
    private nonisolated let streamsAudio: Bool
    private var consumer: Task<Void, any Error>?
    private nonisolated let clock = VoiceRecognitionClock()
    public var timing: VoiceRecognitionTiming { clock.snapshot }
    private var inference: Task<String, any Error>?
    private var modelPreparation: Task<Void, any Error>?
    private var started = false
    private var cancelled = false
    private let hypothesisStore = HypothesisStore()

    public func hypothesis() -> String { hypothesisStore.current() }

    public init(settings: VoiceSettings, onPartial: @escaping @Sendable (String) -> Void) {
        model = settings.localSpeechModel
        backend = settings.speechBackend
        interfazeAPIKey = settings.interfazeAPIKey
        self.settings = settings
        self.onPartial = onPartial
        let stream = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        pcmStream = stream.stream
        pcmContinuation = stream.continuation
        let selected = settings.speechBackend == .apple ? VoiceAPIProtocol.apple
            : settings.speechBackend == .cloud ? settings.asr.resolvedProtocol : nil
        streamsAudio = selected == .apple || selected == .volcStreaming || selected == .bailianStreaming
        let hotwords = settings.vocabulary.selectedHotwords(for: settings.speechBackend == .apple
            ? VoiceEndpoint(baseURL: "apple://speech") : settings.asr)
        let store = hypothesisStore
        let forward: @Sendable (String) -> Void = { text in
            store.store(text)
            onPartial(text)
        }
        apple = selected == .apple ? AppleSpeechRecognition(language: settings.language, hotwords: hotwords, onPartial: forward) : nil
        volc = selected == .volcStreaming ? VolcStreamingRecognition(endpoint: settings.asr, language: settings.language,
            hotwords: hotwords, secondPass: settings.volcSecondPass, onPartial: forward) : nil
        bailian = selected == .bailianStreaming ? BailianStreamingRecognition(endpoint: settings.asr, onPartial: forward) : nil
    }

    public func prepare() async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        if backend == .local {
            try await LocalSpeechRecognizer.shared.checkAvailability(model)
        } else if backend == .interfaze {
            try InterfazeSpeechTranscription.validate(apiKey: interfazeAPIKey)
        } else if backend == .cloud {
            guard settings.asr.isConfigured else { throw VoiceRecognitionError.invalidConfiguration }
        }
    }

    public func start() async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard !started else { throw VoiceCaptureError.alreadyRecording }
        clock.start()
        if backend == .local {
            try await LocalSpeechRecognizer.shared.checkAvailability(model)
        } else if backend == .interfaze {
            try InterfazeSpeechTranscription.validate(apiKey: interfazeAPIKey)
        } else if backend == .cloud {
            guard settings.asr.isConfigured else { throw VoiceRecognitionError.invalidConfiguration }
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        started = true
        if backend == .local {
            modelPreparation = Task.detached(priority: .userInitiated) { [model] in
                try await LocalSpeechRecognizer.shared.prepareModel(model)
            }
        }
        do {
            try await apple?.start()
            try await volc?.start()
            try await bailian?.start()
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            if streamsAudio {
                consumer = Task { @MainActor [pcmStream, apple, volc, bailian] in
                    for try await pcm in pcmStream {
                        try Task.checkCancellation()
                        try apple?.append(pcm)
                        try await volc?.append(pcm)
                        try await bailian?.append(pcm)
                    }
                }
            }
            clock.ready(reused: apple?.reusedRecognizer)
        } catch {
            cancel()
            throw error
        }
    }

    public nonisolated func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        clock.audio()
        guard streamsAudio else { return }
        guard pcm.count.isMultiple(of: 2), pcm.count <= 9_600_000 else {
            pcmContinuation.finish(throwing: VoiceRecognitionError.invalidResponse)
            return
        }
        for offset in stride(from: 0, to: pcm.count, by: 3_200) {
            if case .dropped = pcmContinuation.yield(pcm.subdata(in: offset..<min(offset + 3_200, pcm.count))) {
                pcmContinuation.finish(throwing: VoiceRecognitionError.recognitionFailed)
                return
            }
        }
    }

    public func finish(_ audio: RecordedAudio) async throws -> String {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard started, inference == nil else { throw VoiceCaptureError.notRecording }
        guard audio.duration.isFinite, audio.duration >= 0.1, audio.duration <= 300 else {
            throw VoiceTranscriptionError.emptyRecording
        }
        clock.stop()
        pcmContinuation.finish()
        if streamsAudio {
            let task = Task { @MainActor [self] in
                try await consumer?.value
                try Task.checkCancellation()
                clock.drain()
                if let apple { return try await apple.finish() }
                if let volc { return try await volc.finish() }
                if let bailian { return try await bailian.finish() }
                throw VoiceRecognitionError.invalidConfiguration
            }
            inference = task
            defer { inference = nil; consumer = nil; started = false; apple?.cancel(); volc?.cancel(); bailian?.cancel() }
            let text = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor [weak self] in self?.cancel() }
            }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            clock.text()
            clock.complete()
            return text
        }
        clock.drain()
        let preparation = modelPreparation
        let task = Task.detached(priority: .userInitiated) { [model, backend, interfazeAPIKey, settings] in
            try await preparation?.value
            try Task.checkCancellation()
            if backend == .interfaze {
                return try await InterfazeSpeechTranscription.transcribe(audio, apiKey: interfazeAPIKey)
            }
            if backend == .cloud {
                return try await VoiceTranscriber().transcribe(audio, settings: settings)
            }
            return try await LocalSpeechRecognizer.shared.transcribe(audio, model: model)
        }
        inference = task
        defer { inference = nil; modelPreparation = nil; started = false }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            preparation?.cancel()
            task.cancel()
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        clock.text()
        clock.complete()
        return result
    }

    public func cancel() {
        cancelled = true
        pcmContinuation.finish(throwing: CancellationError())
        consumer?.cancel()
        apple?.cancel()
        volc?.cancel()
        bailian?.cancel()
        modelPreparation?.cancel()
        modelPreparation = nil
        inference?.cancel()
        started = false
    }
}

/// Latest streaming hypothesis. Recognizer callbacks are not tied to one actor.
private final class HypothesisStore: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func store(_ value: String) { lock.withLock { text = value } }
    func current() -> String { lock.withLock { text } }
}

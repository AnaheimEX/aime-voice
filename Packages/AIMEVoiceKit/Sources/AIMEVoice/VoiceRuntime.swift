public import Foundation
import OSLog

// External I/O seams for inert runtime checks. Host callers use only VoiceRuntime.
@MainActor
public protocol VoiceRuntimeCapture: AnyObject {
    var lastStartWasPrewarmed: Bool { get }
    func warmUpIfAuthorized() async -> Bool
    func start(onLevel: @escaping @Sendable (Double) -> Void,
               onPCM: @escaping @Sendable (Data) -> Void,
               onFailure: @escaping @MainActor (VoiceCaptureError) -> Void) async throws
    func stop() async throws -> RecordedAudio
    func cancel()
}

@MainActor
public protocol VoiceRuntimeRecognition: AnyObject {
    var timing: VoiceRecognitionTiming { get }
    var receivePCM: @Sendable (Data) -> Void { get }
    func prepare() async throws
    func start() async throws
    func finish(_ audio: RecordedAudio) async throws -> String
    func hypothesis() -> String
    func cancel()
}

extension VoiceRuntimeRecognition {
    func prepare() async throws {}
    func hypothesis() -> String { "" }
}

public extension VoiceRecorder { }
extension VoiceRecorder: VoiceRuntimeCapture {}
extension VoiceRecognitionSession: VoiceRuntimeRecognition {
    public var receivePCM: @Sendable (Data) -> Void { { [self] pcm in append(pcm) } }
}

/// One runtime per XPC connection, one capture owner across the process.
/// start accepts a request; only the recording event declares capture readiness.
@MainActor
public final class VoiceRuntime {
    public enum Failure: LocalizedError {
        case busy, closed
        public var errorDescription: String? {
            switch self {
            case .busy: "已有语音任务正在运行"
            case .closed: "语音连接已断开，请重新开始录音"
            }
        }
    }
    private static let latencyLogger = Logger(subsystem: "app.zool.aime.voice", category: "latency")
    private static weak var captureOwner: VoiceRuntime?
    private let recorder: any VoiceRuntimeCapture
    private let makeRecognition: (VoiceSettings, @escaping @Sendable (String) -> Void) -> any VoiceRuntimeRecognition
    private let process: (VoiceRequest, String) async throws -> VoiceProcessingResult
    private let now: () -> ContinuousClock.Instant
    private let send: (VoiceEvent) -> Void
    private var recognition: (any VoiceRuntimeRecognition)?
    private var request: VoiceRequest?
    private var task: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var closed = false
    private var recording = false
    private var stopRequested = false
    private var recognitionReady = false
    private var pendingAudio: RecordedAudio?
    private var processingStarted: ContinuousClock.Instant?

    public convenience init(emit: @escaping (VoiceEvent) -> Void) {
        self.init(capture: VoiceRecorder(), makeRecognition: { settings, partial in
            VoiceRecognitionSession(settings: settings, onPartial: partial)
        }, process: { request, transcript in
            if let selected = request.rewriteText {
                return try await VoiceProcessor().rewrite(selected, instruction: transcript,
                    settings: request.settings, singleLine: request.rewriteSingleLine ?? false)
            }
            return try await VoiceProcessor().process(transcript, settings: request.settings)
        }, now: { .now }, emit: emit)
    }

    public init(capture: any VoiceRuntimeCapture,
         makeRecognition: @escaping (VoiceSettings, @escaping @Sendable (String) -> Void) -> any VoiceRuntimeRecognition,
         process: @escaping (VoiceRequest, String) async throws -> VoiceProcessingResult,
         now: @escaping () -> ContinuousClock.Instant,
         emit: @escaping (VoiceEvent) -> Void) {
        recorder = capture
        self.makeRecognition = makeRecognition
        self.process = process
        self.now = now
        send = emit
    }

    public func warmUp() async -> Bool {
        guard !closed, request == nil, Self.captureOwner == nil else { return false }
        guard !SecureEventInputShield.isSecureEventInput() else { return false }
        let generation = self.generation
        let warmed = await recorder.warmUpIfAuthorized()
        return warmed && !closed && request == nil && self.generation == generation && Self.captureOwner == nil
    }

    public func start(_ request: VoiceRequest) throws {
        guard !closed else { throw Failure.closed }
        guard self.request == nil, Self.captureOwner == nil else { throw Failure.busy }
        // A secure-input session (password field, lock screen) must never open the
        // microphone. Refuse before anything is owned or prepared.
        guard !SecureEventInputShield.isSecureEventInput() else {
            self.request = nil
            Self.captureOwner = nil
            emit("error", text: "安全输入状态下不能录音")
            return
        }
        let generation = self.generation
        let receivedAt = now()
        self.request = request
        Self.captureOwner = self
        stopRequested = false
        task = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                let recognition = self.makeRecognition(request.settings) { [weak self] text in
                    Task { @MainActor in
                        guard self?.isCurrent(generation) == true else { return }
                        self?.emit("partial", text: text)
                    }
                }
                self.recognition = recognition
                // Reject missing local weights before opening the microphone.
                try await recognition.prepare()
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                try await self.recorder.start(onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard self?.isCurrent(generation) == true else { return }
                        self?.emit("level", level: level)
                    }
                }, onPCM: recognition.receivePCM, onFailure: { [weak self] error in
                    guard self?.isCurrent(generation) == true else { return }
                    self?.emit("error", text: error.localizedDescription)
                })
                let duration = receivedAt.duration(to: self.now())
                let milliseconds = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
                Self.latencyLogger.notice("stage=xpcStartToRecorderReady startupMs=\(milliseconds) prewarmed=\(self.recorder.lastStartWasPrewarmed)")
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                self.recording = true
                self.emit("recording")
                guard self.isCurrent(generation) else { return }
                if self.stopRequested { self.finishRecording() }
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                try await recognition.start()
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                self.recognitionReady = true
                self.processPendingAudio()
            } catch {
                guard self.isCurrent(generation) else { return }
                self.emit("error", text: Self.message(for: error))
            }
        }
    }

    /// A silent clip is a normal outcome, not a transport failure: say what the
    /// user should do instead of surfacing the recorder's internal wording.
    private static func message(for error: any Error) -> String {
        guard let capture = error as? VoiceCaptureError else { return error.localizedDescription }
        switch capture {
        case .noSpeech: return "没有检测到语音，未发起识别"
        default: return capture.localizedDescription
        }
    }

    public func stop(_ sessionID: String) {
        guard request?.sessionID == sessionID else { return }
        stopRequested = true
        if recording { finishRecording() }
    }

    public func cancel(_ sessionID: String) {
        guard request?.sessionID == sessionID else { return }
        emit("cancelled")
    }

    public func shutdown() {
        guard !closed else { return }
        closed = true
        reset()
    }

    private func finishRecording() {
        guard request != nil, recording else { return }
        let generation = self.generation
        recording = false
        stopTask = Task { @MainActor in
            do {
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                // Stop capture while ASR connects; finalization waits for both
                // the drained capture tail and the recognition consumer.
                processingStarted = now()
                let audio = try await recorder.stop()
                guard !Task.isCancelled, self.isCurrent(generation) else { return }
                pendingAudio = audio
                emit("transcribing")
                guard self.isCurrent(generation) else { return }
                processPendingAudio()
            } catch {
                guard !Task.isCancelled, self.isCurrent(generation) else { return }
                emit("error", text: error.localizedDescription)
            }
        }
    }

    private func processPendingAudio() {
        guard recognitionReady, let request, let audio = pendingAudio,
              let processingStarted else { return }
        let generation = self.generation
        pendingAudio = nil
        task = Task { @MainActor in
            var speculative: Task<VoiceProcessingResult, any Error>?
            do {
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                guard let recognition = self.recognition else { throw VoiceRecognitionError.invalidConfiguration }
                // Rewrite instructions must wait for the final utterance. Dictation can
                // overlap polish with the recognizer's second pass when a hypothesis exists.
                let partial = request.rewriteText == nil
                    ? recognition.hypothesis().trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if !partial.isEmpty {
                    speculative = Task { try await process(request, partial) }
                    guard self.isCurrent(generation) else { speculative?.cancel(); return }
                    self.emit("processing")
                }
                let inFlight = speculative
                let outcome = try await withTaskCancellationHandler {
                    let transcript = try await recognition.finish(audio)
                    Self.latencyLogger.notice("stage=recognition \(recognition.timing.logFields, privacy: .public)")
                    let asrDuration = processingStarted.duration(to: self.now())
                    let asrMilliseconds = Int(asrDuration.components.seconds * 1000) + Int(asrDuration.components.attoseconds / 1_000_000_000_000_000)
                    try Task.checkCancellation()
                    guard self.isCurrent(generation) else {
                        inFlight?.cancel()
                        return Optional<(VoiceProcessingResult, String, Int, String)>.none
                    }
                    let result: VoiceProcessingResult
                    let speculativeState: String
                    if let inFlight, Self.sameUtterance(partial, transcript) {
                        speculativeState = "adopted"
                        result = try await inFlight.value
                    } else {
                        inFlight?.cancel()
                        speculativeState = inFlight == nil ? "skipped" : "replaced"
                        if inFlight == nil { self.emit("processing") }
                        guard self.isCurrent(generation) else { return nil }
                        result = try await process(request, transcript)
                    }
                    return (result, transcript, asrMilliseconds, speculativeState)
                } onCancel: { inFlight?.cancel() }
                guard let outcome else { return }
                let (result, transcript, asrMilliseconds, speculativeState) = outcome
                try Task.checkCancellation()
                guard self.isCurrent(generation) else { return }
                let wall = processingStarted.duration(to: self.now())
                let wallMilliseconds = Int(wall.components.seconds * 1000) + Int(wall.components.attoseconds / 1_000_000_000_000_000)
                // totalAfterStopMs is wall time from stop. processingMs can overlap asrMs when
                // speculative polish is adopted. No transcript or provider data is logged.
                Self.latencyLogger.notice("route=\(result.route, privacy: .public) decisionInvoked=\(result.decisionInvoked) decisionAdopted=\(result.decisionAdopted) asrMs=\(asrMilliseconds) processingMs=\(result.elapsedMilliseconds) totalAfterStopMs=\(wallMilliseconds) speculative=\(speculativeState, privacy: .public)")
                self.emit("completed", text: result.text, transcript: transcript,
                          processing: request.rewriteText == nil ? VoicePolishObservation.Processing(result) : nil)
            } catch {
                speculative?.cancel()
                guard self.isCurrent(generation) else { return }
                self.emit("error", text: error.localizedDescription)
            }
        }
    }

    /// Exact trimmed utterance. Trailing punctuation still counts as a different final result.
    private static func sameUtterance(_ partial: String, _ final: String) -> Bool {
        let lhs = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lhs.isEmpty && lhs == rhs
    }

    private func emit(_ kind: String, text: String = "", level: Double = 0, transcript: String? = nil,
                      processing: VoicePolishObservation.Processing? = nil) {
        guard let request else { return }
        let event = VoiceEvent(sessionID: request.sessionID, kind: kind, text: text, level: level, transcript: transcript,
                               processing: processing)
        // Make the terminal event the completion boundary, including for a
        // synchronous caller that starts its next session from this callback.
        if kind == "completed" || kind == "cancelled" || kind == "error" { reset() }
        send(event)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        request != nil && self.generation == generation
    }

    private func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        stopTask?.cancel()
        stopTask = nil
        recorder.cancel()
        recognition?.cancel()
        recognition = nil
        request = nil
        recording = false
        stopRequested = false
        recognitionReady = false
        pendingAudio = nil
        processingStarted = nil
        if Self.captureOwner === self { Self.captureOwner = nil }
    }
}

import AIMEVoice
import AIMEVoiceHost
import XCTest

/// Fakes for the xpc-backed recorder and recognition layers.
/// Fakes for the xpc-backed recorder and recognition layers.
private final class FakeRecorder: VoiceRuntimeCapture, @unchecked Sendable {
    var lastStartWasPrewarmed = false
    /// Stops with this error; nil means a usable recording.
    var rejection: VoiceCaptureError?
    private var pcm: Data
    private var onLevel: ((Double) -> Void)?
    private var onPCM: ((Data) -> Void)?
    private var onFailure: ((VoiceCaptureError) -> Void)?

    init(pcm: Data, rejection: VoiceCaptureError? = nil) { self.pcm = pcm; self.rejection = rejection }

    func warmUpIfAuthorized() async -> Bool { true }

    func start(onLevel: @escaping @Sendable (Double) -> Void,
               onPCM: @escaping @Sendable (Data) -> Void,
               onFailure: @escaping @MainActor (VoiceCaptureError) -> Void) async throws {
        self.onLevel = onLevel
        self.onPCM = onPCM
        self.onFailure = onFailure
    }

    func stop() async throws -> RecordedAudio {
        if let rejection { throw rejection }
        return RecordedAudio(wav: self.pcm, duration: Double(self.pcm.count) / 32_000)
    }

    func cancel() {}
}

private final class FakeRecognition: VoiceRuntimeRecognition {
    var receivePCM: @Sendable (Data) -> Void = { _ in }
    var timing: VoiceRecognitionTiming {
        VoiceRecognitionTiming(prepareMilliseconds: nil, firstTextMilliseconds: nil,
                               drainMilliseconds: nil, finalizeMilliseconds: nil,
                               totalMilliseconds: nil, appleRecognizerReused: nil)
    }
    func prepare() async throws {}
    func start() async throws {}
    func finish(_ audio: RecordedAudio) async throws -> String { "完整尾音" }
    func hypothesis() -> String { "" }
    func cancel() {}
}

/// A 16 kHz Int16 sample clip, used as the capture's contribution.
private func pcm(frameCount: Int = 32_000, peak: Int16 = 1_000) -> Data {
    var samples = [Int16](repeating: peak, count: frameCount)
    return samples.withUnsafeBytes { Data($0) }
}

@MainActor
private func waits(until predicate: @escaping (VoiceEvent) -> Bool, in events: inout [VoiceEvent]) async -> Bool {
    for _ in 0..<10_000 {
        for event in events {
            if predicate(event) { return true }
        }
        do { try await Task.sleep(nanoseconds: 100_000) } catch { break }
    }
    return false
}

@MainActor
final class VoiceRuntimeTests: XCTestCase {

    /// A full safe utterance emits recording -> transcribing -> processing -> completed.
    func testRoundTrip() async {
        var events: [VoiceEvent] = []
        // The sandbox reports the secure-input state; silence it for recording.
        let probe = SecureEventInputShield.probe
        SecureEventInputShield.probe = { false }
        defer { SecureEventInputShield.probe = probe }
        let capture = FakeRecorder(pcm: pcm())
        let runtime = VoiceRuntime(capture: capture,
                                   makeRecognition: { _, _ in FakeRecognition() },
                                   process: { _, _ in VoiceProcessingResult(text: "整理后", route: "fixture",
                                                                       decisionInvoked: false, decisionAdopted: false,
                                                                       elapsedMilliseconds: 0) },
                                   now: { .now }, emit: { events.append($0) })
        let request = VoiceRequest(sessionID: "one", settings: VoiceSettings())
        do { try runtime.start(request) } catch { XCTFail("start failed: \(error.localizedDescription)") }
        let first = await waits(until: { $0.kind == "recording" }, in: &events)
        XCTAssertTrue(first, "must declare recording")
        runtime.stop(request.sessionID)
        let last = await waits(until: { $0.kind == "completed" }, in: &events)
        XCTAssertTrue(last, "must complete")
        XCTAssertEqual(events.map(\.kind), ["recording", "transcribing", "processing", "completed"])
        XCTAssertTrue(events.last?.text == "整理后" && events.last?.transcript == "完整尾音")
        runtime.shutdown()
    }

    /// A silent capture never reaches the model: no transcript, no polish.
    func testNoSpeechRejects() async {
        var events: [VoiceEvent] = []
        // The sandbox reports the secure-input state; silence it for recording.
        let probe = SecureEventInputShield.probe
        SecureEventInputShield.probe = { false }
        defer { SecureEventInputShield.probe = probe }
        let recorder = FakeRecorder(pcm: pcm(frameCount: 32_000, peak: 0),
                                    rejection: VoiceCaptureError.noSpeech)
        let runtime = VoiceRuntime(capture: recorder,
                                   makeRecognition: { _, _ in FakeRecognition() },
                                   process: { _, _ in VoiceProcessingResult(text: "", route: "",
                                                                       decisionInvoked: false, decisionAdopted: false,
                                                                       elapsedMilliseconds: 0) },
                                   now: { .now }, emit: { events.append($0) })
        let request = VoiceRequest(sessionID: "silent", settings: VoiceSettings())
        do { try runtime.start(request) } catch { XCTFail("start failed: \(error.localizedDescription)") }
        let first = await waits(until: { $0.kind == "recording" }, in: &events)
        XCTAssertTrue(first)
        runtime.stop(request.sessionID)
        let last = await waits(until: { $0.kind == "error" }, in: &events)
        XCTAssertTrue(last)
        XCTAssertEqual(events.map(\.kind), ["recording", "error"])
        XCTAssertTrue(events.last?.text == "没有检测到语音，未发起识别")
        runtime.shutdown()
    }

    /// A secure-input state keeps the microphone closed on start and warmUp.
    func testSecureInput() async {
        let original = SecureEventInputShield.probe
        SecureEventInputShield.probe = { true }
        defer { SecureEventInputShield.probe = original }

        var events: [VoiceEvent] = []
        let runtime = VoiceRuntime(capture: FakeRecorder(pcm: pcm()),
                                   makeRecognition: { _, _ in FakeRecognition() },
                                   process: { _, _ in VoiceProcessingResult(text: "", route: "",
                                                                       decisionInvoked: false, decisionAdopted: false,
                                                                       elapsedMilliseconds: 0) },
                                   now: { .now }, emit: { events.append($0) })
        let request = VoiceRequest(sessionID: "locked", settings: VoiceSettings())
        do { try runtime.start(request) } catch { XCTFail("start failed: \(error.localizedDescription)") }
        let first = await waits(until: { $0.kind == "error" }, in: &events)
        XCTAssertTrue(first, "must declare error")
        XCTAssertTrue(events.last?.text == "安全输入状态下不能录音")
        let warmed = await runtime.warmUp()
        XCTAssertFalse(warmed)
        runtime.shutdown()
    }
}

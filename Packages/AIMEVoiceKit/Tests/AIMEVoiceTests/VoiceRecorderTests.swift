import AIMEVoice
import XCTest

/// Unit tests for the recorder: audio gain is applied per clip and silence
/// never leaves the recorder.
@MainActor
final class VoiceRecorderTests: XCTestCase {

    private static func pcmbuf(peak: Int16, frameCount: Int) -> Data {
        var samples = [Int16](repeating: peak, count: frameCount)
        return samples.withUnsafeBytes { Data($0) }
    }

    private static func firstSample(_ wav: Data) -> Int16 {
        // Standard 44-byte RIFF/WAV header, 16-bit little-endian PCM.
        var sample: Int16 = 0
        for offset in 0..<2 { sample = Int16(wav[44 + offset]) << (8 * offset) | sample }
        return sample
    }

    /// Silent input is rejected by the recorder.
    func testSilenceThrowsNoSpeech() async {
        let transport = FakeTransport(pcm: Self.pcmbuf(peak: 0, frameCount: 32_000))
        let recorder = VoiceRecorder(makeCapture: { transport }, permission: { true },
                                     isAuthorized: { true }, prewarm: {})
        do {
            try await recorder.start(onLevel: { _ in }, onPCM: { _ in })
            try await recorder.stop()
            XCTFail("a silent clip must not be recorded")
        } catch VoiceCaptureError.noSpeech {
            // Incorrect silence never reaches the model.
        } catch {
            XCTFail("wrong error type: \(error.localizedDescription)")
        }
    }

    /// The quiet wave is boosted to the target, the sample count stays.
    func testStopNormalises() async throws {
        // -30 dBFS at peak: the policy aims for -3 dBFS, so 27 dB of gain is
        // capped to 18 and the peak stays below the headroom of Int16.
        let transport = FakeTransport(pcm: Self.pcmbuf(peak: Int16.max / 10, frameCount: 32_000))
        let recorder = VoiceRecorder(makeCapture: { transport }, permission: { true },
                                     isAuthorized: { true }, prewarm: {})
        try await recorder.start(onLevel: { _ in }, onPCM: { _ in })
        let audio = try await recorder.stop()
        let measured = 20 * log10(Float(Self.firstSample(audio.wav)) / Float(Int16.max))
        XCTAssertTrue(measured > -3.5 && measured < -2.5,
                      "gain applied: \(String(format: "%.1f dBFS", measured))")
        // A sample insert at peak -> logs the boost, then 44-byte header + samples.
        // 32_000 Int16 samples at 16 kHz = 2 seconds of audio.
        XCTAssertEqual(audio.duration, 2.0)
        XCTAssertEqual(audio.wav.count, 44 + 32_000 * MemoryLayout<Int16>.size)
    }

    /// A loud clip is written through unmodified.
    func testStopLeavesLoudAlone() async throws {
        let transport = FakeTransport(pcm: Self.pcmbuf(peak: Int16.max - 1, frameCount: 32_000))
        let recorder = VoiceRecorder(makeCapture: { transport }, permission: { true },
                                     isAuthorized: { true }, prewarm: {})
        try await recorder.start(onLevel: { _ in }, onPCM: { _ in })
        let audio = try await recorder.stop()
        // The WAV keeps the original samples after the header.
        XCTAssertTrue(Data(audio.wav.dropFirst(44)) == Self.pcmbuf(peak: Int16.max - 1, frameCount: 32_000))
    }

    /// `cancel` must not leak a half-started capture.
    func testCancelWaitsNothing() async {
        let transport = FakeTransport(pcm: Self.pcmbuf(peak: 0, frameCount: 32_000))
        let recorder = VoiceRecorder(makeCapture: { transport }, permission: { true },
                                     isAuthorized: { true }, prewarm: {})
        recorder.cancel()
        do {
            try await recorder.stop()
            XCTFail("a cancelled capture is not started")
        } catch VoiceCaptureError.notRecording {
            // capture is nil, generation advanced.
        } catch {
            XCTFail("wrong error type: \(error.localizedDescription)")
        }
    }
}

/// A transport that never needs the microphone and commits to a sample clip.
private final class FakeTransport: VoiceCaptureTransport, @unchecked Sendable {
    let pcm: Data
    init(pcm: Data) { self.pcm = pcm }
    func start(onLevel: @escaping @Sendable (Double) -> Void, onPCM: @escaping @Sendable (Data) -> Void,
               onFailure: @escaping @Sendable (VoiceCaptureError) -> Void) async throws {}
    func stop() async throws -> Data { pcm }
    func cancel() {}
}

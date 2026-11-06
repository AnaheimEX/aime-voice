import AIMEVoice
import XCTest

/// Unit tests for the recording-gain policy: quiet speech is fed worse audio
/// than loud speech, and silence never reaches the model.
final class AudioGainTests: XCTestCase {

    private static func pcmbuf(peak: Int16, frameCount: Int) -> Data {
        var samples = [Int16](repeating: peak, count: frameCount)
        return samples.withUnsafeBytes { Data($0) }
    }

    /// Sample at reference `dBFS` for a 16 kHz capture (frameunned, single channel).
    private static func sample(dbfs: Float) -> Int16 {
        Int16(round(Float(Int16.max) * pow(10, dbfs / 20)))
    }

    func testPeakDBFSIsLossless() {
        for peak in [1, 327, 3276, 16384, 32766] {
            let raw = Self.pcmbuf(peak: Int16(peak), frameCount: 1_000)
            XCTAssertEqual(AudioGain.peakSample(raw), peak)
            let measured = AudioGain.peakDBFS(raw)
            let expected = 20 * log10(Float(peak) / Float(Int16.max))
            XCTAssertEqual(measured, expected, accuracy: 1e-6)
        }
    }

    /// Total silence (literally an empty peak) is silent.
    func testSilence() {
        XCTAssertTrue(AudioGain.isSilent(Self.pcmbuf(peak: 0, frameCount: 1_000)))
        XCTAssertEqual(AudioGain.peakDBFS(Self.pcmbuf(peak: 0, frameCount: 4)), -(.infinity))
    }

    /// Silence is returned untouched by normalisation.
    func testSilenceIsUntouched() {
        let silent = Self.pcmbuf(peak: 0, frameCount: 4_000)
        XCTAssertTrue(AudioGain.normalised(silent) == silent)
    }

    /// A -40 dBFS sample is boosted by the 18 dB cap, landing near -22 dBFS.
    func testBoostQuietSpeech() {
        let raw = Self.pcmbuf(peak: Self.sample(dbfs: -40), frameCount: 32_000)
        let boosted = AudioGain.normalised(raw)
        let measured = AudioGain.peakDBFS(boosted)
        XCTAssertTrue(measured > -23 && measured < -21, "boosted by the 18 dB cap: \(String(format: "%.1f dBFS", measured))")
    }

    /// +18 dB above -21 dBFS lands exactly on the -3 dBFS target.
    func testBoostHitsTarget() {
        let raw = Self.pcmbuf(peak: Self.sample(dbfs: -21), frameCount: 32_000)
        let boosted = AudioGain.normalised(raw)
        let measured = AudioGain.peakDBFS(boosted)
        XCTAssertTrue(measured > -3.2 && measured < -2.8, "target -3 dBFS: \(String(format: "%.1f dBFS", measured))")
    }

    /// Loud audio must be untouched.
    func testLoudAudioIsUntouched() {
        let raw = Self.pcmbuf(peak: Int16.max - 1, frameCount: 32_000)
        XCTAssertTrue(AudioGain.normalised(raw) == raw)
    }

    /// A would-be clipped gain saturates the sample at Int16.max.
    func testNeverClips() {
        let raw = Self.pcmbuf(peak: Int16.max - 1_000, frameCount: 32_000)
        let boosted = AudioGain.normalised(raw)
        let measured = AudioGain.peakDBFS(boosted)
        XCTAssertTrue(measured > -3 && measured < 0, "saturated, not clipped: \(String(format: "%.1f dBFS", measured))")
    }

    /// Gain must not change the number of samples, so WAV duration stays correct.
    func testDurationIsStable() {
        let raw = Self.pcmbuf(peak: Self.sample(dbfs: -40), frameCount: 32_000)
        XCTAssertEqual(AudioGain.normalised(raw).count, raw.count)
    }
}

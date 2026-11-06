// Peak-based software gain applied to a finished recording.
// The policy (same one used for the VoiceFlow inline stack):
// boost toward a fixed target, never attenuate loud audio, cap the boost,
// never clip.
public import Foundation
import OSLog

/// Gain for a recording that is alternated to dBFS-limited speech.
///
/// Quiet speech is the single most common reason a short utterance comes back
/// empty: the transcriber receives "好的" at -35 dBFS. The recorder metered the
/// level for the UI but never adjusted the signal, so quiet speakers were simply
/// served worse audio.
///
/// The policy is deliberately conservative:
///   - boost toward a fixed target, never attenuate loud audio,
///   - cap the boost so room noise is not amplified into hiss,
///   - never clip.
///
/// The meter still reports the raw level (what the control surface shows); only
/// the waveform handed off to the model is normalised.
public enum AudioGain {

    /// Loudest sample we aim for. -3 dBFS leaves headroom after boosting.
    public static let targetDBFS: Float = -3

    /// Upper bound on boost. Beyond ~18 dB the noise floor dominates.
    public static let maxGainDB: Float = 18

    internal static let logger = Logger(subsystem: "app.zool.aime.voice", category: "gain")

    // MARK: - Measurement

    public static func peakSample(_ pcm: Data) -> Int {
        var maximum: Int = 0
        pcm.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Int16.self)
            for value in buffer {
                let magnitude = value.magnitude
                if magnitude > maximum { maximum = Int(magnitude) }
            }
        }
        return maximum
    }

    /// Peak level in dBFS. Silence returns `-infinity`.
    public static func peakDBFS(_ pcm: Data) -> Float {
        let peak = peakSample(pcm)
        guard peak > 0 else { return -.infinity }
        return 20 * log10(Float(peak) / Float(Int16.max))
    }

    /// True when the clip is effectively silence.
    ///
    /// A silent window makes the model invent speech ("各位，请便" appeared
    /// from nothing). Skipping those is cheaper and more accurate than sending
    /// them.
    public static func isSilent(_ pcm: Data, thresholdDBFS: Float = -50) -> Bool {
        let peak = peakSample(pcm)
        guard peak > 0 else { return true }
        return peakDBFS(pcm) < thresholdDBFS
    }

    // MARK: - Normalisation

    /// Boost quiet audio toward `targetDBFS`.
    ///
    /// Returns the input untouched when it is silent, already loud enough, or
    /// when no gain would be applied.
    public static func normalised(
        _ pcm: Data,
        targetDBFS: Float = AudioGain.targetDBFS,
        maxGainDB: Float = AudioGain.maxGainDB
    ) -> Data {
        let peak = peakSample(pcm)
        guard !pcm.isEmpty, peak > 0 else { return pcm }

        let measured = 20 * log10(Float(peak) / Float(Int16.max))
        let wanted = min(maxGainDB, max(0, targetDBFS - measured))
        guard wanted > 0.5 else { return pcm }
        let factor = pow(10, wanted / 20)
        let output = scale(pcm, by: factor)
        guard peakSample(output) <= Int16.max else {
            // Never clip: back off the gain entirely and return the original.
            logger.error("gain: peak would clip, returning unmodified: \(String(format: "%.1f", measured)) dBFS")
            return pcm
        }
        let improved = 20 * log10(Float(peakSample(output)) / Float(Int16.max))
        logger.notice("gain \(String(format: "%+.1f dB", wanted))  \(String(format: "%.1f -> %+.1f dBFS", measured, improved))  \(pcm.count / 32_000)s")
        return output
    }
}

/// Linear sample scaling with saturation, so the boosted waveform never clips.
private func scale(_ pcm: Data, by factor: Float) -> Data {
    var output = Data(capacity: pcm.count)
    pcm.withUnsafeBytes { raw in
        for sample in raw.bindMemory(to: Int16.self) {
            let scaled = Double(sample) * Double(factor)
            let clamped = Swift.min(Swift.max(scaled, -Double(Int16.max - 1)), Double(Int16.max - 1))
            // Append little-endian so the WAV shape matches the recorder's format.
            let value = Int16(clamped)
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        }
    }
    return output
}

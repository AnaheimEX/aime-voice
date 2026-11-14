// Audio format follows Type4Me's 16 kHz mono Int16 capture pipeline.
// Type4Me Copyright (c) joewongjc, licensed under the MIT License.
public import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import OSLog

public struct RecordedAudio: Sendable {
    public let wav: Data
    public let duration: Double

    public init(wav: Data, duration: Double) {
        self.wav = wav
        self.duration = duration
    }
}

public enum VoiceCaptureError: LocalizedError, Sendable {
    case permissionDenied, alreadyRecording, unavailable, notRecording, conversionFailed, tooLong
    /// A secure-input session (password field, lock screen) must never open the mic.
    case secureInput
    /// The recording contained no speech above the silence floor.
    case noSpeech

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "请在系统设置的隐私与安全性中允许 AIME 语音使用麦克风"
        case .alreadyRecording: "录音已经开始"
        case .unavailable: "没有可用的麦克风输入"
        case .notRecording: "当前没有录音"
        case .conversionFailed: "无法转换麦克风音频"
        case .tooLong: "单次录音不能超过 5 分钟"
        case .secureInput: "安全输入状态下不能录音"
        case .noSpeech: "没有听清，请再说一遍"
        }
    }
}

// The facade owns cancellation generations; capture hardware and conversion never
// run on MainActor. The transport seam lets lifecycle tests avoid the microphone.
/// Seam for lifecycle tests: no microphone, no permission prompt.
public protocol VoiceCaptureTransport: AnyObject, Sendable {
    func start(onLevel: @escaping @Sendable (Double) -> Void,
               onPCM: @escaping @Sendable (Data) -> Void,
               onFailure: @escaping @Sendable (VoiceCaptureError) -> Void) async throws
    func stop() async throws -> Data
    func cancel()
}

@MainActor
public final class VoiceRecorder {
    private var capture: (any VoiceCaptureTransport)?
    private var starting = false
    private var stopping = false
    private var generation: UInt64 = 0
    private var warmed = false
    public private(set) var lastStartWasPrewarmed = false
    private let makeCapture: () -> any VoiceCaptureTransport
    private let permission: () async -> Bool
    private let isAuthorized: () -> Bool
    private let prewarm: @Sendable () async -> Void
    private static let logger = Logger(subsystem: "app.zool.aime.voice", category: "latency")

    public init() {
        makeCapture = { FluidVoiceCapture() }
        permission = Self.requestPermission
        isAuthorized = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        prewarm = { await FluidVoiceCapture.warmUp() }
    }

    public init(makeCapture: @escaping () -> any VoiceCaptureTransport,
                permission: @escaping () async -> Bool,
                isAuthorized: @escaping () -> Bool,
                prewarm: @escaping @Sendable () async -> Void) {
        self.makeCapture = makeCapture
        self.permission = permission
        self.isAuthorized = isAuthorized
        self.prewarm = prewarm
    }

    /// Enumerate the default input without opening capture or requesting permission.
    @discardableResult
    public func warmUpIfAuthorized() async -> Bool {
        guard !starting, !stopping, capture == nil, isAuthorized() else { return false }
        if warmed { return true }
        let begin = ContinuousClock.now
        await prewarm()
        warmed = true
        Self.logger.notice("stage=recorderWarmUp setupMs=\(Self.milliseconds(begin.duration(to: .now)))")
        return true
    }

    private static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default: return false
        }
    }

    public func start(onLevel: @escaping @Sendable (Double) -> Void,
                      onPCM: @escaping @Sendable (Data) -> Void,
                      onFailure: @escaping @MainActor (VoiceCaptureError) -> Void = { _ in }) async throws {
        guard capture == nil, !starting, !stopping else { throw VoiceCaptureError.alreadyRecording }
        starting = true
        generation &+= 1
        let id = generation
        let begin = ContinuousClock.now
        defer { if generation == id { starting = false } }
        let authorized = await permission()
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        guard authorized else { throw VoiceCaptureError.permissionDenied }
        let permitted = ContinuousClock.now
        let transport = makeCapture()
        capture = transport
        lastStartWasPrewarmed = warmed
        do {
            try await withTaskCancellationHandler {
                try await transport.start(onLevel: onLevel, onPCM: onPCM) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.capture != nil else { return }
                        onFailure(error)
                    }
                }
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
            } onCancel: { transport.cancel() }
            warmed = true
            Self.logger.notice("stage=recorderStart backend=fluid-coreaudio permissionMs=\(Self.milliseconds(begin.duration(to: permitted))) captureStartMs=\(Self.milliseconds(permitted.duration(to: .now))) prewarmed=\(self.lastStartWasPrewarmed)")
        } catch {
            transport.cancel()
            if generation == id { capture = nil }
            throw error
        }
    }

    public func stop() async throws -> RecordedAudio {
        guard let transport = capture, !starting, !stopping else { throw VoiceCaptureError.notRecording }
        stopping = true
        let id = generation
        defer {
            if generation == id { capture = nil; stopping = false }
        }
        let pcm = try await transport.stop()
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        // Quiet speech is the most common reason a short utterance comes back
        // empty: the transcriber receives "好的" at -35 dBFS. Boost toward the
        // target before measuring silence — gain never attenuates and never clips.
        let gained = AudioGain.normalised(pcm)
        // A silent clip never reaches the model: ASR would hallucinate a tail.
        guard !AudioGain.isSilent(gained) else { throw VoiceCaptureError.noSpeech }
        return RecordedAudio(wav: Self.makeWAV(gained), duration: Double(gained.count) / 32_000)
    }

    public func cancel() {
        generation &+= 1
        capture?.cancel()
        capture = nil
        starting = false
        stopping = false
    }

    fileprivate nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func makeWAV(_ pcm: Data) -> Data {
        var result = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        result.append(contentsOf: "RIFF".utf8)
        append(UInt32(pcm.count + 36))
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count))
        result.append(pcm)
        return result
    }
}

// The tap and the main actor share this state. Every converter access and state
// mutation is protected by the lock. The PCM callback must only enqueue its
// data, without reentering this recorder, to preserve capture and tail ordering.
final class PCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var pcm = Data()
    private var active = true
    private var failure: VoiceCaptureError?
    private let onPCM: @Sendable (Data) -> Void
    private static let maximumBytes = 16_000 * 2 * 300

    init?(sourceFormat: AVAudioFormat, onPCM: @escaping @Sendable (Data) -> Void) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                        channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else { return nil }
        self.target = target
        self.converter = converter
        self.onPCM = onPCM
        pcm.reserveCapacity(320_000)
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard active, failure == nil else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 128)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            failure = .conversionFailed
            return nil
        }
        // AVAudioConverter invokes this synchronously under the accumulator lock.
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else {
            failure = .conversionFailed
            return nil
        }
        return store(output)
    }

    private func store(_ output: AVAudioPCMBuffer) -> Double? {
        let count = Int(output.frameLength)
        guard count > 0, let samples = output.int16ChannelData?[0] else { return nil }
        guard pcm.count + count * 2 <= Self.maximumBytes else {
            failure = .tooLong
            return nil
        }
        let chunk = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        pcm.append(chunk)
        onPCM(chunk)
        var sumSquares: Int64 = 0
        for index in 0..<count {
            let s = Int64(samples[index])
            sumSquares += s * s
        }
        let meanSquare = Double(sumSquares) / (Double(count) * 1_073_741_824.0)
        return min(1, sqrt(meanSquare) * 4)
    }

    var captureFailure: VoiceCaptureError? { lock.withLock { failure } }

    func finish() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        active = false
        // Finish the converter so the final resampling frames are not discarded.
        if failure == nil, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1024) {
            for _ in 0..<16 {
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if status == .error || error != nil { failure = .conversionFailed; break }
                _ = store(output)
                if status == .endOfStream || output.frameLength == 0 { break }
            }
        }
        if let failure { throw failure }
        return pcm
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        pcm.removeAll(keepingCapacity: false)
    }
}

// CoreMedia copies each channel into the correct buffer, including planar PCM.
// A single block-buffer memcpy would corrupt non-interleaved stereo input.
func voicePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
          let format = AVAudioFormat(streamDescription: asbd) else { return nil }
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frames > 0, frames <= Int(Int32.max),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                      into: buffer.mutableAudioBufferList) == noErr else { return nil }
    return buffer
}

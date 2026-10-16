// Adapts FluidVoice CoreAudioCaptureSupport, GPL-3.0, pinned at 2ca292d.
// See licenses/fluidvoice.LICENSE.txt and THIRD_PARTY_NOTICES.md.
import Foundation
import CoreAudio
import FluidCaptureSupport
@preconcurrency import AVFoundation

/// Hardware callbacks publish to FluidVoice's C ring; conversion runs on a worker.
/// The existing recorder facade retains permission, generation and WAV ownership.
final class FluidVoiceCapture: VoiceCaptureTransport, @unchecked Sendable {
    private static let control = DispatchQueue(label: "app.zool.aime.voice.fluid-control", qos: .userInitiated)
    // A failed HAL stop must never free live callback memory or admit another recorder.
    private static nonisolated(unsafe) var hardwarePoisoned = false // control queue only
    private static nonisolated(unsafe) var hardwareInUse = false // control queue only
    private let worker = DispatchQueue(label: "app.zool.aime.voice.fluid-samples", qos: .userInitiated)
    private let drained = DispatchGroup()
    private let lock = NSLock()
    private var cancelled = false
    private var workerFailure: VoiceCaptureError? // lock protected
    private var capture: FVCoreAudioCaptureRef? // control queue only
    private var accumulator: PCMAccumulator?
    private var formatInvalid = false // control queue only
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    static func warmUp() async {
        // Enumerate the default device without opening or starting it.
        _ = try? defaultDevice()
    }

    func start(onLevel: @escaping @Sendable (Double) -> Void,
               onPCM: @escaping @Sendable (Data) -> Void,
               onFailure: @escaping @Sendable (VoiceCaptureError) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Self.control.async { [self] in
                do {
                    guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                    guard !Self.hardwarePoisoned, !Self.hardwareInUse, capture == nil else { throw VoiceCaptureError.unavailable }
                    let device = try Self.defaultDevice()
                    var handle: FVCoreAudioCaptureRef?
                    guard fv_core_audio_capture_create(device, &handle) == noErr, let handle else {
                        throw VoiceCaptureError.unavailable
                    }
                    capture = handle
                    Self.hardwareInUse = true
                    let rate = fv_core_audio_capture_sample_rate(handle)
                    guard rate.isFinite, rate > 0,
                          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                     channels: 1, interleaved: false),
                          let accumulator = PCMAccumulator(sourceFormat: format, onPCM: onPCM) else {
                        throw VoiceCaptureError.conversionFailed
                    }
                    self.accumulator = accumulator
                    var streamID = AudioStreamID(kAudioObjectUnknown)
                    var streamFormat = AudioStreamBasicDescription()
                    guard fv_core_audio_capture_copy_stream_format(handle, &streamID, &streamFormat) else {
                        throw VoiceCaptureError.unavailable
                    }
                    try installListeners(device: device, stream: streamID, onFailure: onFailure)
                    guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                    guard fv_core_audio_capture_start(handle) == noErr,
                          fv_core_audio_capture_open_packet_gate_if_clean(handle) else {
                        throw VoiceCaptureError.unavailable
                    }
                    let box = CaptureHandle(value: handle)
                    drained.enter()
                    worker.async { [self] in
                        defer { drained.leave() }
                        var reportedFailure = false
                        while true {
                            // Observe stop before draining: a callback can publish between
                            // the last peek and AudioDeviceStop returning on the control queue.
                            let running = fv_core_audio_capture_is_running(box.value)
                            var packet = FVCoreAudioPacket()
                            while fv_core_audio_capture_peek(box.value, &packet) {
                                if let samples = packet.samples, packet.frameCount > 0 {
                                    let count = AVAudioFrameCount(packet.frameCount)
                                    if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                                       let target = buffer.floatChannelData?[0] {
                                        buffer.frameLength = count
                                        target.update(from: samples, count: Int(count))
                                        if let level = accumulator.append(buffer) { onLevel(level) }
                                        if !reportedFailure, let failure = accumulator.captureFailure {
                                            reportedFailure = true
                                            lock.withLock { workerFailure = failure }
                                            onFailure(failure)
                                        }
                                    } else if !reportedFailure {
                                        reportedFailure = true
                                        lock.withLock { workerFailure = .conversionFailed }
                                        onFailure(.conversionFailed)
                                    }
                                }
                                fv_core_audio_capture_consume(box.value)
                            }
                            guard running else { break }
                            _ = fv_core_audio_capture_wait(box.value, 100)
                        }
                    }
                    guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    _ = try? teardown(discard: true)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Self.control.async { [self] in
                continuation.resume(with: Result { try teardown(discard: false) })
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        Self.control.async { [self] in _ = try? teardown(discard: true) }
    }

    private func teardown(discard: Bool) throws -> Data {
        guard let handle = capture else {
            if discard { return Data() }
            throw VoiceCaptureError.notRecording
        }
        let status = fv_core_audio_capture_stop(handle)
        fv_core_audio_capture_wake(handle)
        drained.wait()
        for (object, originalAddress, listener) in listeners {
            var address = originalAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, Self.control, listener)
        }
        listeners.removeAll()
        capture = nil
        defer { accumulator = nil; Self.hardwareInUse = false }
        guard status == noErr else {
            Self.hardwarePoisoned = true
            accumulator?.cancel()
            // Keep the C allocation alive: HAL may still hold its callback pointer.
            throw VoiceCaptureError.unavailable
        }
        let dropped = fv_core_audio_capture_dropped_packet_count(handle)
        let destroyed = fv_core_audio_capture_destroy(handle)
        guard destroyed == noErr else {
            Self.hardwarePoisoned = true
            accumulator?.cancel()
            throw VoiceCaptureError.unavailable
        }
        if discard { accumulator?.cancel(); return Data() }
        if let failure = lock.withLock({ workerFailure }) {
            accumulator?.cancel()
            throw failure
        }
        guard dropped == 0, !formatInvalid else { accumulator?.cancel(); throw VoiceCaptureError.unavailable }
        return try accumulator?.finish() ?? Data()
    }

    private func installListeners(device: AudioObjectID, stream: AudioStreamID,
                                  onFailure: @escaping @Sendable (VoiceCaptureError) -> Void) throws {
        let properties: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
            (stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal),
        ]
        for (object, selector, scope) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, let handle = self.capture else { return }
                self.formatInvalid = true
                fv_core_audio_capture_mark_format_dirty(handle)
                onFailure(.unavailable)
            }
            guard AudioObjectAddPropertyListenerBlock(object, &address, Self.control, listener) == noErr else {
                throw VoiceCaptureError.unavailable
            }
            listeners.append((object, address, listener))
        }
    }

    private static func defaultDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != kAudioObjectUnknown else {
            throw VoiceCaptureError.unavailable
        }
        return device
    }

    private struct CaptureHandle: @unchecked Sendable { let value: FVCoreAudioCaptureRef }
}

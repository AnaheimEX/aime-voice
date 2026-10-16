// No microphone or permission prompts. Exercise the public recording lifecycle
// with controlled transports, plus real CoreMedia and AVAudioConverter PCM.
import Foundation
import AVFoundation
import CoreMedia

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var count = 0
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func increment() { lock.withLock { count += 1 } }
    var bytes: Data { lock.withLock { data } }
    var value: Int { lock.withLock { count } }
}

private final class Capture: VoiceCaptureTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startGate: CheckedContinuation<Void, any Error>?
    private var stopGate: CheckedContinuation<Data, any Error>?
    private var failure: (@Sendable (VoiceCaptureError) -> Void)?
    private var pcm: (@Sendable (Data) -> Void)?
    let holdStart: Bool
    let holdStop: Bool
    let reject: Bool
    let cancellations = Box()
    let starts = Box()
    init(holdStart: Bool = false, holdStop: Bool = false, reject: Bool = false) {
        self.holdStart = holdStart; self.holdStop = holdStop; self.reject = reject
    }
    func start(onLevel: @escaping @Sendable (Double) -> Void,
               onPCM: @escaping @Sendable (Data) -> Void,
               onFailure: @escaping @Sendable (VoiceCaptureError) -> Void) async throws {
        lock.withLock { failure = onFailure; pcm = onPCM }
        if reject { throw VoiceCaptureError.unavailable }
        if holdStart {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { startGate = continuation }
                starts.increment()
            }
        } else { starts.increment() }
        onPCM(Data([1, 0]))
    }
    func stop() async throws -> Data {
        if holdStop {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { stopGate = continuation }
            }
        }
        lock.withLock { pcm }?(Data([2, 0]))
        return Data([1, 0, 2, 0])
    }
    func cancel() { cancellations.increment() }
    func finishStart() { lock.withLock { let c = startGate; startGate = nil; return c }?.resume() }
    var waitingForStop: Bool { lock.withLock { stopGate != nil } }
    func finishStop() { lock.withLock { let c = stopGate; stopGate = nil; return c }?.resume(returning: Data([3, 0])) }
    func reportFailure() { lock.withLock { failure }?(.unavailable) }
}

@main struct VoiceRecorderLifecycleCheck {
    @MainActor static func settle() async { for _ in 0..<50 { await Task.yield() } }
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let cancelledHardware = FluidVoiceCapture()
        cancelledHardware.cancel()
        do {
            try await cancelledHardware.start(onLevel: { _ in }, onPCM: { _ in }, onFailure: { _ in })
            fatalError("cancelled transport opened hardware")
        } catch is CancellationError { checks += 1 }
        var granted = false
        var permissionCalls = 0
        var captures: [Capture] = []
        let warmups = Box()
        let recorder = VoiceRecorder(makeCapture: { let c = Capture(); captures.append(c); return c },
            permission: { permissionCalls += 1; return granted }, isAuthorized: { granted },
            prewarm: { warmups.increment() })
        let skipped = await recorder.warmUpIfAuthorized()
        check(!skipped && warmups.value == 0 && permissionCalls == 0 && captures.isEmpty,
              "idle warmup must not prompt or touch capture without authorization")
        do { try await recorder.start(onLevel: { _ in }, onPCM: { _ in }); fatalError("permission denied start accepted") }
        catch VoiceCaptureError.permissionDenied { check(captures.isEmpty, "denied start must not create capture") }
        granted = true
        let warm = await recorder.warmUpIfAuthorized()
        let warmAgain = await recorder.warmUpIfAuthorized()
        check(warm && warmAgain && warmups.value == 1 && captures.isEmpty,
              "warmup initializes framework once without opening capture")
        let streamed = Box()
        try await recorder.start(onLevel: { _ in }, onPCM: { streamed.append($0) })
        check(recorder.lastStartWasPrewarmed && streamed.bytes == Data([1, 0]), "first PCM must stream before stop")
        let activeWarmup = await recorder.warmUpIfAuthorized()
        check(!activeWarmup, "warmup must not overlap capture")
        do { try await recorder.start(onLevel: { _ in }, onPCM: { _ in }); fatalError("overlap accepted") }
        catch VoiceCaptureError.alreadyRecording { checks += 1 }
        let result = try await recorder.stop()
        check(result.wav.prefix(4) == Data("RIFF".utf8) && result.wav.count == 48, "stop must preserve WAV container")
        check(result.wav.suffix(4) == streamed.bytes && streamed.bytes == Data([1, 0, 2, 0]), "stop drains streaming tail before WAV")
        check(result.duration == 4.0 / 32_000, "duration must match 16k mono Int16")
        do { _ = try await recorder.stop(); fatalError("duplicate stop accepted") }
        catch VoiceCaptureError.notRecording { checks += 1 }
        try await recorder.start(onLevel: { _ in }, onPCM: { _ in })
        check(captures.count == 2, "each recording gets a fresh capture transport")
        recorder.cancel()
        check(captures[1].cancellations.value == 1, "cancel must release current capture")
        granted = false
        let revoked = await recorder.warmUpIfAuthorized()
        check(!revoked, "previous warmup must not bypass revoked permission")

        var authorization: CheckedContinuation<Bool, Never>?
        var permissionCaptures = 0
        let pendingPermission = VoiceRecorder(makeCapture: { permissionCaptures += 1; return Capture() },
            permission: { await withCheckedContinuation { authorization = $0 } },
            isAuthorized: { false }, prewarm: {})
        let waiting = Task { try await pendingPermission.start(onLevel: { _ in }, onPCM: { _ in }) }
        await settle()
        pendingPermission.cancel()
        authorization?.resume(returning: true)
        do { try await waiting.value; fatalError("cancelled permission opened capture") }
        catch is CancellationError { check(permissionCaptures == 0, "late permission grant must not open microphone") }

        let delayed = Capture(holdStart: true)
        let replacement = Capture()
        var attempt = 0
        var errors = 0
        let racing = VoiceRecorder(makeCapture: { attempt += 1; return attempt == 1 ? delayed : replacement },
            permission: { true }, isAuthorized: { true }, prewarm: {})
        let late = Task { try await racing.start(onLevel: { _ in }, onPCM: { _ in }, onFailure: { _ in errors += 1 }) }
        while delayed.starts.value == 0 { await Task.yield() }
        racing.cancel()
        try await racing.start(onLevel: { _ in }, onPCM: { _ in }, onFailure: { _ in errors += 1 })
        delayed.finishStart()
        delayed.reportFailure()
        do { try await late.value; fatalError("late start revived cancelled session") }
        catch is CancellationError { checks += 1 }
        await settle()
        check(errors == 0 && replacement.cancellations.value == 0, "stale callbacks must not cancel replacement capture")
        replacement.reportFailure()
        await settle()
        check(errors == 1, "active capture failure must reach owner")
        racing.cancel()

        let cancelledStart = Capture(holdStart: true)
        let taskRecorder = VoiceRecorder(makeCapture: { cancelledStart }, permission: { true }, isAuthorized: { true }, prewarm: {})
        let task = Task { try await taskRecorder.start(onLevel: { _ in }, onPCM: { _ in }) }
        while cancelledStart.starts.value == 0 { await Task.yield() }
        task.cancel()
        cancelledStart.finishStart()
        do { try await task.value; fatalError("task cancellation ignored") }
        catch is CancellationError { check(cancelledStart.cancellations.value > 0, "task cancellation releases capture") }

        let slowStop = Capture(holdStop: true)
        let fresh = Capture()
        var stopAttempt = 0
        let stopping = VoiceRecorder(makeCapture: { stopAttempt += 1; return stopAttempt == 1 ? slowStop : fresh },
            permission: { true }, isAuthorized: { true }, prewarm: {})
        try await stopping.start(onLevel: { _ in }, onPCM: { _ in })
        let finishing = Task { try await stopping.stop() }
        while !slowStop.waitingForStop { await Task.yield() }
        stopping.cancel()
        try await stopping.start(onLevel: { _ in }, onPCM: { _ in })
        slowStop.finishStop()
        do { _ = try await finishing.value; fatalError("cancelled stop published audio") }
        catch is CancellationError { checks += 1 }
        let newAudio = try await stopping.stop()
        check(newAudio.wav.suffix(4) == Data([1, 0, 2, 0]), "late stop must not clear replacement recording")

        var fail = true
        let retry = VoiceRecorder(makeCapture: { Capture(reject: fail) }, permission: { true }, isAuthorized: { true }, prewarm: {})
        do { try await retry.start(onLevel: { _ in }, onPCM: { _ in }); fatalError("failed hardware start accepted") }
        catch VoiceCaptureError.unavailable { checks += 1 }
        fail = false
        try await retry.start(onLevel: { _ in }, onPCM: { _ in })
        _ = try await retry.stop()
        checks += 1

        // Real CoreMedia ingress: planar stereo must retain both channels.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        pcm.frameLength = 4800
        for i in 0..<4800 { pcm.floatChannelData![0][i] = 0.25; pcm.floatChannelData![1][i] = 0.5 }
        var description: CMAudioFormatDescription?
        check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, "create synthetic audio format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        check(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 4800,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "create synthetic sample")
        check(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
            "attach planar audio")
        let decoded = voicePCMBuffer(from: sample!)!
        check(decoded.frameLength == 4800 && decoded.floatChannelData![0][100] == 0.25 && decoded.floatChannelData![1][100] == 0.5,
              "CoreMedia ingress must copy both planar channels without corruption")
        let output = Box()
        let accumulator = PCMAccumulator(sourceFormat: decoded.format, onPCM: { output.append($0) })!
        _ = accumulator.append(decoded)
        let finalPCM = try accumulator.finish()
        check(finalPCM == output.bytes && !finalPCM.isEmpty, "resampler flush must match streaming PCM")
        check(abs(finalPCM.count - 3200) <= 64, "48k stereo input must become approximately 100ms of 16k mono Int16")
        print("PASS \(checks) recorder lifecycle/PCM checks; no microphone capture")
    }
}

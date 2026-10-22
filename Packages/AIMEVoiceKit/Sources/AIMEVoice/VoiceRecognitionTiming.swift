public import Foundation

/// Metadata only. Callback threads record their first event without a MainActor hop.
public struct VoiceRecognitionTiming: Sendable {
    public let prepareMilliseconds: Int?
    public let firstTextMilliseconds: Int?
    public let drainMilliseconds: Int?
    public let finalizeMilliseconds: Int?
    public let totalMilliseconds: Int?
    public let appleRecognizerReused: Bool?

    public var logFields: String {
        func value(_ number: Int?) -> String { number.map(String.init) ?? "pending" }
        return "prepareMs=\(value(prepareMilliseconds)) firstTextMs=\(value(firstTextMilliseconds)) drainMs=\(value(drainMilliseconds)) finalMs=\(value(finalizeMilliseconds)) recognitionTotalMs=\(value(totalMilliseconds)) appleRecognizerReused=\(appleRecognizerReused.map(String.init) ?? "na")"
    }
}

final class VoiceRecognitionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var started: ContinuousClock.Instant?
    private var ready: ContinuousClock.Instant?
    private var audio: ContinuousClock.Instant?
    private var firstText: ContinuousClock.Instant?
    private var stopped: ContinuousClock.Instant?
    private var drained: ContinuousClock.Instant?
    private var completed: ContinuousClock.Instant?
    private var reused: Bool?

    func start(at time: ContinuousClock.Instant = .now) { lock.withLock { if started == nil { started = time } } }
    func ready(reused: Bool?, at time: ContinuousClock.Instant = .now) { lock.withLock { ready = time; self.reused = reused } }
    func audio(at time: ContinuousClock.Instant = .now) { lock.withLock { if audio == nil { audio = time } } }
    func text(at time: ContinuousClock.Instant = .now) { lock.withLock { if firstText == nil { firstText = time } } }
    func stop(at time: ContinuousClock.Instant = .now) { lock.withLock { if stopped == nil { stopped = time } } }
    func drain(at time: ContinuousClock.Instant = .now) { lock.withLock { drained = time } }
    func complete(at time: ContinuousClock.Instant = .now) { lock.withLock { completed = time } }

    var snapshot: VoiceRecognitionTiming {
        lock.withLock {
            func milliseconds(_ from: ContinuousClock.Instant?, _ to: ContinuousClock.Instant?) -> Int? {
                guard let from, let to else { return nil }
                let elapsed = from.duration(to: to)
                return max(0, Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
            }
            return VoiceRecognitionTiming(
                prepareMilliseconds: milliseconds(started, ready),
                firstTextMilliseconds: milliseconds(audio ?? started, firstText),
                drainMilliseconds: milliseconds(stopped, drained),
                finalizeMilliseconds: milliseconds(drained, completed),
                totalMilliseconds: milliseconds(started, completed),
                appleRecognizerReused: reused
            )
        }
    }
}

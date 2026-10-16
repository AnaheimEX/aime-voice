import Foundation
@testable import AIMEVoice

@MainActor
private final class Capture: VoiceRuntimeCapture {
    var lastStartWasPrewarmed = false
    var ready: CheckedContinuation<Void, any Error>?
    var failures: [@MainActor (VoiceCaptureError) -> Void] = []
    var draining: CheckedContinuation<Void, any Error>?
    var holdDrain = false
    var pcm: (@Sendable (Data) -> Void)?
    var level: (@Sendable (Double) -> Void)?
    var started = false
    var rejectStart = false
    var rejectStop = false
    var cancelledStopAttempt = false
    var warmAllowed = true
    var holdWarm = false
    var warming: CheckedContinuation<Void, Never>?
    func warmUpIfAuthorized() async -> Bool {
        guard warmAllowed else { return false }
        if holdWarm { await withCheckedContinuation { warming = $0 } }
        return true
    }
    func start(onLevel: @escaping @Sendable (Double) -> Void,
               onPCM: @escaping @Sendable (Data) -> Void,
               onFailure: @escaping @MainActor (VoiceCaptureError) -> Void) async throws {
        failures.append(onFailure)
        pcm = onPCM
        level = onLevel
        if rejectStart { throw VoiceCaptureError.permissionDenied }
        try await withCheckedThrowingContinuation { ready = $0 }
        started = true
        onPCM(Data([1, 0]))
    }
    func stop() async throws -> RecordedAudio {
        if Task.isCancelled { cancelledStopAttempt = true }
        if rejectStop { throw VoiceCaptureError.conversionFailed }
        if holdDrain { try await withCheckedThrowingContinuation { draining = $0 } }
        pcm?(Data([2, 0]))
        return RecordedAudio(wav: Data([1, 0, 2, 0]), duration: 1)
    }
    func cancel() {}
}

private final class PCM: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var value: Data { lock.withLock { bytes } }
}

@MainActor
private final class Recognition: VoiceRuntimeRecognition {
    private nonisolated let pcm = PCM()
    var holdHandshake = false
    var handshake: CheckedContinuation<Void, any Error>?
    var captureReady: () -> Bool = { true }
    var rejectStart = false
    var rejectFinish = false
    var holdFinish = false
    var finishing: CheckedContinuation<Void, any Error>?
    var timing: VoiceRecognitionTiming { VoiceRecognitionClock().snapshot }
    var receivePCM: @Sendable (Data) -> Void { { [pcm] data in pcm.append(data) } }
    func start() async throws {
        if rejectStart { throw VoiceRecognitionError.invalidConfiguration }
        guard captureReady() else { throw VoiceCaptureError.notRecording }
        if holdHandshake { try await withCheckedThrowingContinuation { handshake = $0 } }
    }
    var hypothesisText = ""
    func hypothesis() -> String { hypothesisText }
    func finish(_ audio: RecordedAudio) async throws -> String {
        if holdFinish { try await withCheckedThrowingContinuation { finishing = $0 } }
        if rejectFinish { throw VoiceRecognitionError.recognitionFailed }
        guard audio.wav == Data([1, 0, 2, 0]), pcm.value == Data([1, 0, 2, 0]) else {
            throw VoiceCaptureError.conversionFailed
        }
        return "完整尾音"
    }
    func cancel() {}
}

@main
struct VoiceRuntimeCheck {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    @MainActor static func until(_ predicate: () -> Bool) async {
        for _ in 0..<10000 {
            if predicate() { return }
            await Task.yield()
        }
        fatalError("fixture did not reach expected state")
    }
    @MainActor static func main() async throws {
        let capture = Capture()
        var events: [VoiceEvent] = []
        let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in Recognition() },
            process: { _, _ in fatalError("must not process cancelled capture") },
            now: { .now }, emit: { events.append($0) })
        let other = VoiceRuntime(capture: Capture(), makeRecognition: { _, _ in Recognition() },
            process: { _, _ in fatalError("must not process") }, now: { .now }, emit: { _ in })
        let request = VoiceRequest(sessionID: "one", settings: VoiceSettings())
        try runtime.start(request)
        await until { capture.ready != nil }
        check(events.isEmpty, "accepting start must not claim recording before capture readiness")
        do {
            try other.start(request)
            fatalError("second XPC connection acquired an occupied capture")
        } catch VoiceRuntime.Failure.busy {}
        runtime.cancel("one")
        check(events.map(\.kind) == ["cancelled"], "cancel must terminate exactly once")
        try other.start(request)
        other.shutdown()
        capture.ready?.resume()
        capture.ready = nil
        await Task.yield()
        runtime.shutdown()
        print("PASS runtime ownership, readiness and cancellation")
        try await lateCaptureCannotTerminateReplacement()
        try await stopDuringPreparationDrainsBeforeProcessing()
        try await terminalDeliveryReleasesOwnershipBeforeCallback()
        try await shutdownClosesRPCAndWarmUp()
        try await cancellationAtProcessingEventDoesNotSubmitModelRequest()
        try await eachExternalFailureTerminatesOnceAndReleasesOwnership()
        try await lateExternalResultsCannotAffectAnotherConnection()
        try await warmupPreservesAuthorizationAndRejectsStaleReadiness()
        try await cancelledQueuedStopDoesNotTouchCapture()
        try await matchingPartialIsPolishedWhileRecognitionFinishes()
        try await differentFinalReplacesPartialPolish()
        try await rewriteWaitsForFinalInstruction()
    }

    @MainActor static func lateCaptureCannotTerminateReplacement() async throws {
        let capture = Capture()
        var events: [VoiceEvent] = []
        let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in Recognition() },
            process: { _, _ in fatalError("cancelled sessions must not process") },
            now: { .now }, emit: { events.append($0) })
        let request = VoiceRequest(sessionID: "reused-wire-id", settings: VoiceSettings())
        try runtime.start(request)
        await until { capture.ready != nil }
        let oldReady = capture.ready!
        capture.ready = nil
        runtime.cancel(request.sessionID)
        try runtime.start(request)
        await until { capture.ready != nil }
        capture.failures[0](.unavailable)
        check(events.map(\.kind) == ["cancelled"], "late capture failure terminated replacement with reused wire ID")
        oldReady.resume()
        for _ in 0..<20 { await Task.yield() }
        check(events.map(\.kind) == ["cancelled"], "old cancelled task emitted a replacement error")
        runtime.cancel(request.sessionID)
        capture.ready?.resume()
        capture.ready = nil
        runtime.shutdown()
        print("PASS cancelled generation cannot affect replacement")
    }

    @MainActor static func stopDuringPreparationDrainsBeforeProcessing() async throws {
        let capture = Capture()
        capture.holdDrain = true
        let recognition = Recognition()
        recognition.holdHandshake = true
        recognition.captureReady = { capture.started }
        var events: [VoiceEvent] = []
        let fixedTime = ContinuousClock.now
        let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in recognition },
            process: { request, transcript in
                check(request.rewriteText == "旧内容" && request.rewriteSingleLine == true,
                      "processing lost rewrite context")
                return VoiceProcessingResult(text: "改写：" + transcript, route: "fixture",
                    decisionInvoked: false, decisionAdopted: false, elapsedMilliseconds: 0)
            }, now: { fixedTime }, emit: { events.append($0) })
        try runtime.start(VoiceRequest(sessionID: "drain", settings: VoiceSettings(),
            rewriteText: "旧内容", rewriteSingleLine: true))
        await until { capture.ready != nil }
        runtime.stop("drain")
        runtime.stop("drain")
        check(events.isEmpty, "stop during preparation claimed readiness")
        capture.ready?.resume()
        capture.ready = nil
        await until { capture.draining != nil && recognition.handshake != nil }
        check(events.map(\.kind) == ["recording"], "capture/handshake ordering or premature processing")
        capture.draining?.resume()
        capture.draining = nil
        await until { events.contains { $0.kind == "transcribing" } }
        check(events.map(\.kind) == ["recording", "transcribing"], "processing began before handshake readiness")
        runtime.stop("drain")
        recognition.handshake?.resume()
        recognition.handshake = nil
        await until { events.contains { $0.kind == "completed" || $0.kind == "error" } }
        check(events.map(\.kind) == ["recording", "transcribing", "processing", "completed"],
              "one stop must produce one complete event sequence")
        check(events.last?.text == "改写：完整尾音" && events.last?.transcript == "完整尾音",
              "final result must contain drained audio and original transcript")
        runtime.shutdown()
        print("PASS stop during preparation drains tail and waits for recognition, rewrite context preserved")
    }

    @MainActor static func terminalDeliveryReleasesOwnershipBeforeCallback() async throws {
        let capture = Capture()
        var events: [VoiceEvent] = []
        var replacementAccepted = false
        var runtime: VoiceRuntime!
        runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in Recognition() },
            process: { _, _ in fatalError("unexpected processing") }, now: { .now }, emit: { event in
                events.append(event)
                if event.kind == "cancelled", event.sessionID == "old" {
                    do {
                        try runtime.start(VoiceRequest(sessionID: "new", settings: VoiceSettings()))
                        replacementAccepted = true
                    } catch {}
                }
            })
        try runtime.start(VoiceRequest(sessionID: "old", settings: VoiceSettings()))
        await until { capture.ready != nil }
        let oldReady = capture.ready!
        capture.ready = nil
        runtime.cancel("old")
        check(replacementAccepted, "terminal event exposed stale ownership to its caller")
        await until { capture.ready != nil }
        oldReady.resume()
        for _ in 0..<20 { await Task.yield() }
        check(events.count == 1, "terminal delivery cleanup affected replacement")
        runtime.cancel("new")
        capture.ready?.resume()
        capture.ready = nil
        runtime.shutdown()
        runtime = nil
        print("PASS terminal event releases resources before reentrant caller")
    }

    @MainActor static func shutdownClosesRPCAndWarmUp() async throws {
        let capture = Capture()
        var events: [VoiceEvent] = []
        let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in Recognition() },
            process: { _, _ in fatalError("unexpected processing") }, now: { .now }, emit: { events.append($0) })
        let other = VoiceRuntime(capture: Capture(), makeRecognition: { _, _ in Recognition() },
            process: { _, _ in fatalError("unexpected processing") }, now: { .now }, emit: { _ in })
        let idleWarm = await runtime.warmUp()
        check(idleWarm, "idle runtime must preserve recorder warmup result")
        try runtime.start(VoiceRequest(sessionID: "disconnect", settings: VoiceSettings()))
        await until { capture.ready != nil }
        let activeWarm = await runtime.warmUp()
        let competingWarm = await other.warmUp()
        check(!activeWarm && !competingWarm, "warmup must not overlap process-wide capture ownership")
        runtime.shutdown()
        runtime.shutdown()
        capture.ready?.resume()
        capture.ready = nil
        for _ in 0..<20 { await Task.yield() }
        check(events.isEmpty, "disconnected runtime emitted a late event")
        let closedWarm = await runtime.warmUp()
        check(!closedWarm, "disconnected runtime accepted a queued warmup RPC")
        var accepted = false
        do { try runtime.start(VoiceRequest(sessionID: "late-rpc", settings: VoiceSettings())); accepted = true }
        catch {}
        check(!accepted, "disconnected runtime accepted a queued start RPC")
        try other.start(VoiceRequest(sessionID: "other", settings: VoiceSettings()))
        other.shutdown()
        print("PASS shutdown releases ownership and rejects late RPCs, warmup remains idle-only")
    }

    @MainActor static func cancellationAtProcessingEventDoesNotSubmitModelRequest() async throws {
        let capture = Capture()
        var events: [VoiceEvent] = []
        var modelRequested = false
        var runtime: VoiceRuntime!
        runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in Recognition() },
            process: { _, transcript in
                modelRequested = true
                return VoiceProcessingResult(text: transcript, route: "fixture", decisionInvoked: false,
                    decisionAdopted: false, elapsedMilliseconds: 0)
            }, now: { .now }, emit: { event in
                events.append(event)
                if event.kind == "processing" { runtime.cancel(event.sessionID) }
            })
        try runtime.start(VoiceRequest(sessionID: "cancel-before-network", settings: VoiceSettings()))
        await until { capture.ready != nil }
        capture.ready?.resume()
        capture.ready = nil
        await until { events.contains { $0.kind == "recording" } }
        runtime.stop("cancel-before-network")
        await until { events.contains { $0.kind == "cancelled" } }
        for _ in 0..<20 { await Task.yield() }
        check(!modelRequested, "cancelled session submitted a model request after its processing event")
        check(events.map(\.kind) == ["recording", "transcribing", "processing", "cancelled"],
              "cancelled processing emitted another terminal result")
        runtime.shutdown()
        runtime = nil
        print("PASS synchronous cancellation prevents external model submission")
    }

    @MainActor static func eachExternalFailureTerminatesOnceAndReleasesOwnership() async throws {
        let expected: [String: (String, [String])] = [
            "capture-start": (VoiceCaptureError.permissionDenied.localizedDescription, ["error"]),
            "capture-callback": (VoiceCaptureError.unavailable.localizedDescription, ["error"]),
            "capture-stop": (VoiceCaptureError.conversionFailed.localizedDescription, ["recording", "error"]),
            "recognition-start": (VoiceRecognitionError.invalidConfiguration.localizedDescription, ["recording", "error"]),
            "recognition-finish": (VoiceRecognitionError.recognitionFailed.localizedDescription, ["recording", "transcribing", "error"]),
            "processing": (VoiceRecognitionError.invalidResponse.localizedDescription, ["recording", "transcribing", "processing", "error"]),
        ]
        for stage in ["capture-start", "capture-callback", "capture-stop", "recognition-start", "recognition-finish", "processing"] {
            let capture = Capture()
            let recognition = Recognition()
            capture.rejectStart = stage == "capture-start"
            capture.rejectStop = stage == "capture-stop"
            recognition.rejectStart = stage == "recognition-start"
            recognition.rejectFinish = stage == "recognition-finish"
            var events: [VoiceEvent] = []
            let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in recognition },
                process: { _, _ in throw VoiceRecognitionError.invalidResponse },
                now: { .now }, emit: { events.append($0) })
            try runtime.start(VoiceRequest(sessionID: stage, settings: VoiceSettings()))
            if !capture.rejectStart {
                await until { capture.ready != nil }
                if stage == "capture-callback" { capture.failures[0](.unavailable) }
                capture.ready?.resume()
                capture.ready = nil
                if !recognition.rejectStart && stage != "capture-callback" {
                    await until { events.contains { $0.kind == "recording" } }
                    runtime.stop(stage)
                }
            }
            await until { events.contains { $0.kind == "error" } }
            capture.failures[0](.unavailable)
            runtime.cancel(stage)
            runtime.stop(stage)
            for _ in 0..<20 { await Task.yield() }
            check(events.filter { ["error", "cancelled", "completed"].contains($0.kind) }.count == 1,
                  "\(stage) emitted multiple terminal results")
            check(events.last?.text == expected[stage]?.0 && events.map(\.kind) == expected[stage]?.1,
                  "\(stage) exposed the wrong failure or performed work beyond the failed stage")
            // A different connection can capture after every failure, even if
            // the old connection subsequently shuts down.
            let other = VoiceRuntime(capture: Capture(), makeRecognition: { _, _ in Recognition() },
                process: { _, _ in fatalError("unexpected processing") }, now: { .now }, emit: { _ in })
            try other.start(VoiceRequest(sessionID: "replacement", settings: VoiceSettings()))
            runtime.shutdown()
            do {
                try runtime.start(VoiceRequest(sessionID: "closed", settings: VoiceSettings()))
                fatalError("closed connection restarted")
            } catch VoiceRuntime.Failure.closed {}
            other.shutdown()
            print("PASS \(stage) failure emits one terminal event and releases ownership")
        }
    }

    @MainActor static func lateExternalResultsCannotAffectAnotherConnection() async throws {
        for stage in ["handshake", "drain", "finish", "processing"] {
            let capture = Capture()
            capture.holdDrain = stage == "drain"
            let recognition = Recognition()
            recognition.holdHandshake = stage == "handshake"
            recognition.holdFinish = stage == "finish"
            var events: [VoiceEvent] = []
            var partial: (@Sendable (String) -> Void)?
            var processing: CheckedContinuation<Void, any Error>?
            let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, callback in
                partial = callback
                return recognition
            }, process: { _, transcript in
                if stage == "processing" { try await withCheckedThrowingContinuation { processing = $0 } }
                return VoiceProcessingResult(text: transcript, route: "fixture", decisionInvoked: false,
                    decisionAdopted: false, elapsedMilliseconds: 0)
            }, now: { .now }, emit: { events.append($0) })
            try runtime.start(VoiceRequest(sessionID: "same-wire-id", settings: VoiceSettings()))
            await until { capture.ready != nil }
            capture.ready?.resume()
            capture.ready = nil
            await until { events.contains { $0.kind == "recording" } }
            partial?("部分文字")
            capture.level?(0.5)
            await until { events.contains { $0.kind == "partial" } && events.contains { $0.kind == "level" } }
            check(events.first { $0.kind == "partial" }?.text == "部分文字"
                && events.first { $0.kind == "level" }?.level == 0.5,
                "live recognition/capture events were not forwarded")
            runtime.stop("wrong-id")
            runtime.cancel("wrong-id")
            check(!events.contains { $0.kind == "cancelled" || $0.kind == "transcribing" },
                  "foreign stop/cancel changed the active session")
            if stage != "handshake" { runtime.stop("same-wire-id") }
            await until {
                recognition.handshake != nil || capture.draining != nil
                    || recognition.finishing != nil || processing != nil
            }
            runtime.cancel("same-wire-id")
            let countAtCancel = events.count
            let replacementCapture = Capture()
            let replacement = VoiceRuntime(capture: replacementCapture, makeRecognition: { _, _ in Recognition() },
                process: { _, _ in fatalError("unexpected processing") }, now: { .now }, emit: { _ in })
            try replacement.start(VoiceRequest(sessionID: "same-wire-id", settings: VoiceSettings()))
            await until { replacementCapture.ready != nil }
            recognition.handshake?.resume()
            recognition.handshake = nil
            capture.draining?.resume()
            capture.draining = nil
            recognition.finishing?.resume()
            recognition.finishing = nil
            processing?.resume()
            processing = nil
            partial?("迟到文字")
            capture.level?(0.9)
            capture.failures[0](.unavailable)
            for _ in 0..<50 { await Task.yield() }
            check(events.count == countAtCancel && events.last?.kind == "cancelled",
                  "late \(stage) completion emitted an event after cancellation")
            do {
                try runtime.start(VoiceRequest(sessionID: "probe", settings: VoiceSettings()))
                fatalError("late \(stage) completion released another connection's ownership")
            } catch VoiceRuntime.Failure.busy {}
            runtime.shutdown()
            replacement.shutdown()
            replacementCapture.ready?.resume()
            replacementCapture.ready = nil
            print("PASS cancelled \(stage) ignores late results, callbacks and foreign IDs")
        }
    }

    @MainActor static func warmupPreservesAuthorizationAndRejectsStaleReadiness() async throws {
        for action in ["start", "shutdown"] {
            let capture = Capture()
            capture.warmAllowed = false
            var events: [VoiceEvent] = []
            let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in Recognition() },
                process: { _, _ in fatalError("unexpected processing") }, now: { .now }, emit: { events.append($0) })
            let denied = await runtime.warmUp()
            check(!denied && events.isEmpty, "idle warmup must preserve denied authorization without events")
            capture.warmAllowed = true
            capture.holdWarm = true
            let warmup = Task { await runtime.warmUp() }
            await until { capture.warming != nil }
            if action == "start" {
                try runtime.start(VoiceRequest(sessionID: "during-warmup", settings: VoiceSettings()))
                await until { capture.ready != nil }
            } else { runtime.shutdown() }
            capture.warming?.resume()
            capture.warming = nil
            let ready = await warmup.value
            check(!ready && events.isEmpty, "warmup returned stale readiness after \(action)")
            if action == "start" {
                runtime.cancel("during-warmup")
                capture.ready?.resume()
                capture.ready = nil
                capture.holdWarm = false
                let idleAgain = await runtime.warmUp()
                check(idleAgain, "cancelled runtime must allow authorized idle warmup again")
            }
            runtime.shutdown()
            print("PASS warmup preserves authorization and invalidates readiness after \(action)")
        }
    }

    @MainActor static func cancelledQueuedStopDoesNotTouchCapture() async throws {
        let capture = Capture()
        var events: [VoiceEvent] = []
        var runtime: VoiceRuntime!
        runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in Recognition() },
            process: { _, _ in fatalError("unexpected processing") }, now: { .now }, emit: { event in
                events.append(event)
                if event.kind == "recording" {
                    runtime.stop(event.sessionID)
                    runtime.cancel(event.sessionID)
                }
            })
        try runtime.start(VoiceRequest(sessionID: "queued-stop", settings: VoiceSettings()))
        await until { capture.ready != nil }
        capture.ready?.resume()
        capture.ready = nil
        await until { events.contains { $0.kind == "cancelled" } }
        for _ in 0..<50 { await Task.yield() }
        check(!capture.cancelledStopAttempt, "cancelled queued stop touched the capture device")
        check(events.map(\.kind) == ["recording", "cancelled"], "queued stop emitted late events")
        runtime.shutdown()
        runtime = nil
        print("PASS cancelled queued stop cannot touch capture")
    }

    @MainActor static func matchingPartialIsPolishedWhileRecognitionFinishes() async throws {
        let capture = Capture()
        let recognition = Recognition()
        recognition.holdFinish = true
        recognition.hypothesisText = "完整尾音"
        let probe = Probe()
        var events: [VoiceEvent] = []
        let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in recognition },
            process: { _, transcript in
                probe.add(transcript)
                return VoiceProcessingResult(text: "出:" + transcript, route: "fixture",
                    decisionInvoked: false, decisionAdopted: false, elapsedMilliseconds: 7)
            }, now: { .now }, emit: { events.append($0) })
        try runtime.start(VoiceRequest(sessionID: "partial-match", settings: VoiceSettings()))
        await until { capture.ready != nil }
        capture.ready?.resume()
        capture.ready = nil
        await until { events.contains { $0.kind == "recording" } }
        runtime.stop("partial-match")
        await until { recognition.finishing != nil && probe.values == ["完整尾音"] }
        check(!events.contains { $0.kind == "completed" }, "matching partial committed before the final result")
        check(events.map(\.kind) == ["recording", "transcribing", "processing"],
              "polish must start before final recognition")
        recognition.finishing?.resume()
        recognition.finishing = nil
        await until { events.contains { $0.kind == "completed" || $0.kind == "error" } }
        check(events.map(\.kind) == ["recording", "transcribing", "processing", "completed"],
              "matching partial must not process twice")
        check(events.last?.text == "出:完整尾音" && events.last?.transcript == "完整尾音",
              "adopted result must use the partial polish")
        check(probe.values == ["完整尾音"], "matching final must not start a second polish")
        runtime.shutdown()
        print("PASS matching partial is polished while recognition finishes")
    }

    @MainActor static func differentFinalReplacesPartialPolish() async throws {
        let capture = Capture()
        let recognition = Recognition()
        recognition.holdFinish = true
        recognition.hypothesisText = "旧假设"
        let probe = Probe()
        var events: [VoiceEvent] = []
        let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in recognition },
            process: { _, transcript in
                probe.add(transcript)
                if transcript == "旧假设" {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { probe.hold($0) }
                    } onCancel: { probe.release() }
                }
                return VoiceProcessingResult(text: "出:" + transcript, route: "fixture",
                    decisionInvoked: false, decisionAdopted: false, elapsedMilliseconds: 7)
            }, now: { .now }, emit: { events.append($0) })
        try runtime.start(VoiceRequest(sessionID: "partial-mismatch", settings: VoiceSettings()))
        await until { capture.ready != nil }
        capture.ready?.resume()
        capture.ready = nil
        await until { events.contains { $0.kind == "recording" } }
        runtime.stop("partial-mismatch")
        await until { recognition.finishing != nil && probe.values == ["旧假设"] }
        recognition.finishing?.resume()
        recognition.finishing = nil
        await until { events.contains { $0.kind == "completed" || $0.kind == "error" } }
        check(events.last?.kind == "completed" && events.last?.text == "出:完整尾音"
              && events.last?.transcript == "完整尾音", "a different final must replace the partial polish")
        check(probe.values == ["旧假设", "完整尾音"] && probe.didRelease,
              "the partial polish must be cancelled when the final text differs")
        runtime.shutdown()
        print("PASS a different final replaces partial polish")
    }

    @MainActor static func rewriteWaitsForFinalInstruction() async throws {
        let capture = Capture()
        let recognition = Recognition()
        recognition.holdFinish = true
        recognition.hypothesisText = "不要用这个"
        let probe = Probe()
        var events: [VoiceEvent] = []
        let runtime = VoiceRuntime(capture: capture, makeRecognition: { _, _ in recognition },
            process: { request, transcript in
                probe.add(transcript)
                check(request.rewriteText == "旧内容", "rewrite lost its selected text")
                return VoiceProcessingResult(text: "改写：" + transcript, route: "fixture",
                    decisionInvoked: false, decisionAdopted: false, elapsedMilliseconds: 0)
            }, now: { .now }, emit: { events.append($0) })
        try runtime.start(VoiceRequest(sessionID: "rewrite-final", settings: VoiceSettings(),
            rewriteText: "旧内容", rewriteSingleLine: true))
        await until { capture.ready != nil }
        capture.ready?.resume()
        capture.ready = nil
        await until { events.contains { $0.kind == "recording" } }
        runtime.stop("rewrite-final")
        await until { recognition.finishing != nil }
        check(probe.values.isEmpty, "rewrite started from the partial instruction")
        recognition.finishing?.resume()
        recognition.finishing = nil
        await until { events.contains { $0.kind == "completed" || $0.kind == "error" } }
        check(events.last?.text == "改写：完整尾音" && probe.values == ["完整尾音"],
              "rewrite must process only the final instruction")
        runtime.shutdown()
        print("PASS rewrite waits for the final instruction")
    }
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private var held: CheckedContinuation<Void, any Error>?
    private var cancelled = false
    private var released = false
    func add(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
    var didRelease: Bool { lock.withLock { released } }
    func hold(_ continuation: CheckedContinuation<Void, any Error>) {
        let resumeNow: Bool
        lock.lock()
        if cancelled {
            resumeNow = true
        } else {
            held = continuation
            resumeNow = false
        }
        lock.unlock()
        if resumeNow { continuation.resume(throwing: CancellationError()) }
    }
    func release() {
        lock.lock()
        cancelled = true
        released = true
        let continuation = held
        held = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

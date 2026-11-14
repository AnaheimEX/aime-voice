// Microphone-free checks at the XPC boundary. The real bridge runs against an
// inert NSXPCConnection subclass; no service is launched and no credentials load.
import Foundation
import AIMEVoice

private final class Service: NSObject, VoiceServiceProtocol, @unchecked Sendable {
    var accept = true
    var hold = false
    var replies: [(Bool, String) -> Void] = []
    var stops: [String] = []
    var cancels: [String] = []
    var warmReplies: [(Bool) -> Void] = []
    func warmUp(_ reply: @escaping (Bool) -> Void) { warmReplies.append(reply) }
    func ping(_ reply: @escaping () -> Void) { reply() }
    func start(_ data: Data, reply: @escaping (Bool, String) -> Void) {
        replies.append(reply)
        if !hold { reply(accept, accept ? "" : "rejected") }
    }
    func stop(_ id: String) { stops.append(id) }
    func cancel(_ id: String) { cancels.append(id) }
}
private final class Connection: NSXPCConnection, @unchecked Sendable {
    let service = Service()
    var invalidations = 0
    var proxyError: ((any Error) -> Void)?
    override func resume() {}
    override func invalidate() { invalidations += 1 }
    override var remoteObjectProxy: Any { service }
    override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (any Error) -> Void) -> Any {
        proxyError = handler
        return service
    }
}
@main struct VoiceBridgeLifecycleCheck {
    @MainActor static func settle() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }; checks += 1
        }
        func request(_ id: String) -> VoiceRequest { VoiceRequest(sessionID: id, settings: VoiceSettings()) }
        var readinessConnections: [Connection] = []
        let readinessChannel = VoiceServiceChannel(makeConnection: {
            let c = Connection(machServiceName: "test.recording-readiness")
            readinessConnections.append(c)
            return c
        })
        let readiness = VoiceServiceBridge(channel: readinessChannel, startTimeout: .milliseconds(30))
        var readinessErrors = 0
        readiness.onEvent = { if $0.kind == "error" { readinessErrors += 1 } }
        try await readiness.start(request("accepted-but-not-recording"))
        try await Task.sleep(for: .milliseconds(70))
        check(readinessErrors == 1 && readinessConnections[0].invalidations == 1,
              "accepted request without recording readiness must time out and release connection")
        try await readiness.start(request("recording-ready"))
        readinessChannel.receive(try JSONEncoder().encode(VoiceEvent(sessionID: "recording-ready", kind: "recording")))
        await settle()
        try await Task.sleep(for: .milliseconds(70))
        check(readinessErrors == 1 && readinessConnections[1].invalidations == 0,
              "recording readiness must disarm startup timeout")
        readiness.cancel()
        try await readiness.start(request("cancel-before-ready"))
        readiness.cancel()
        try await Task.sleep(for: .milliseconds(70))
        check(readinessConnections[1].invalidations == 0,
              "cancelled preparation must not invalidate a reusable connection later")

        var separatePermissionConnections: [Connection] = []
        let disabledConnection = Connection(machServiceName: "test.disable-idle-service")
        let disabledChannel = VoiceServiceChannel(makeConnection: { disabledConnection })
        disabledChannel.warmUpIfAuthorized(enabled: true)
        disabledChannel.warmUpIfAuthorized(enabled: false)
        check(disabledConnection.invalidations == 1,
              "disabling voice must release the idle XPC service lifetime")
        let activeDisableConnection = Connection(machServiceName: "test.disable-active-service")
        let activeDisableChannel = VoiceServiceChannel(makeConnection: { activeDisableConnection })
        let activeDisable = VoiceServiceBridge(channel: activeDisableChannel)
        try await activeDisable.start(request("disable-active"))
        activeDisableChannel.warmUpIfAuthorized(enabled: false)
        check(activeDisableConnection.invalidations == 0, "disable must let owner cancel its recording first")
        activeDisable.cancel()
        check(activeDisableConnection.invalidations == 1,
              "cancellation after disabling must release service lifetime")
        let separatePermission = VoiceServiceChannel(makeConnection: {
            let c = Connection(machServiceName: "test.capture-permission"); separatePermissionConnections.append(c); return c
        })
        separatePermission.warmUpIfAuthorized(enabled: true)
        check(separatePermissionConnections.count == 1, "host permission must not suppress capture-service authorization check")
        separatePermissionConnections[0].service.warmReplies[0](false)
        await settle()
        check(separatePermissionConnections[0].invalidations == 0, "capture permission refusal still keeps harmless XPC connection warm")
        var warmed: [Connection] = []
        let warming = VoiceServiceChannel(makeConnection: {
            let c = Connection(machServiceName: "test.warmup"); warmed.append(c); return c
        }, warmUpDeadline: .milliseconds(30))
        warming.warmUpIfAuthorized(enabled: false)
        check(warmed.isEmpty, "disabled voice must not launch a service")
        warming.warmUpIfAuthorized(enabled: true)
        warming.warmUpIfAuthorized(enabled: true)
        check(warmed.count == 1 && warmed[0].service.warmReplies.count == 1 && warming.owner == nil,
              "pending warmup must deduplicate without owning a recording")
        let duringWarmup = VoiceServiceBridge(channel: warming)
        try await duringWarmup.start(request("during-warmup"))
        warming.warmUpIfAuthorized(enabled: true)
        check(warmed[0].service.warmReplies.count == 1 && warmed.count == 1,
              "start must reuse pending connection without waiting; active warmup is ignored")
        warmed[0].service.warmReplies[0](false)
        await settle()
        duringWarmup.stop()
        check(warmed[0].invalidations == 0 && warmed[0].service.stops == ["during-warmup"],
              "warmup failure must not discard an active recording")
        duringWarmup.cancel()
        warming.warmUpIfAuthorized(enabled: true)
        warmed[0].service.warmReplies[1](true)
        await settle()
        warming.warmUpIfAuthorized(enabled: true)
        check(warmed[0].service.warmReplies.count == 2, "successful warmup must deduplicate until disconnect")
        warmed[0].interruptionHandler?()
        await settle()
        warming.warmUpIfAuthorized(enabled: true)
        check(warmed.count == 2, "disconnected warmup must reconnect on next explicit request")
        warmed[0].service.warmReplies[1](false)
        await settle()
        check(warmed[1].invalidations == 0, "old warmup reply must not discard a replacement connection")
        try await Task.sleep(for: .milliseconds(70))
        check(warmed[1].invalidations == 1 && warming.owner == nil,
              "unanswered idle warmup must release its connection on timeout")
        warming.warmUpIfAuthorized(enabled: true)
        try await duringWarmup.start(request("warmup-timeout-active"))
        try await Task.sleep(for: .milliseconds(70))
        duringWarmup.stop()
        check(warmed[2].invalidations == 0 && warmed[2].service.stops == ["warmup-timeout-active"],
              "warmup timeout must not interrupt an active recording")
        duringWarmup.cancel()
        warming.warmUpIfAuthorized(enabled: true)
        warmed[2].proxyError?(NSError(domain: "warmup", code: 1))
        await settle()
        check(warmed[2].invalidations == 1, "idle warmup proxy failure must discard connection")
        var connections: [Connection] = []
        let channel = VoiceServiceChannel(makeConnection: {
            let connection = Connection(machServiceName: "test.inert")
            connections.append(connection)
            return connection
        })
        let first = VoiceServiceBridge(channel: channel)
        try await first.start(request("first"))
        first.stop()
        check(connections[0].service.stops == ["first"], "stop must target current session")
        first.cancel()
        let second = VoiceServiceBridge(channel: channel)
        try await second.start(request("second"))
        check(connections.count == 1 && connections[0].invalidations == 0,
              "a new recording bridge must reuse the idle connection")
        var events: [String] = []
        second.onEvent = { events.append($0.kind) }
        channel.receive(try JSONEncoder().encode(VoiceEvent(sessionID: "first", kind: "completed")))
        channel.receive(try JSONEncoder().encode(VoiceEvent(sessionID: "second", kind: "recording")))
        await settle()
        check(events == ["recording"], "old-session events must be ignored")
        do { try await first.start(request("overlap")); fatalError("overlap allowed") } catch {}
        first.cancel()
        second.stop()
        check(connections[0].service.stops == ["first", "second"], "inactive bridge must not cancel current owner")
        let oldInterruption = connections[0].interruptionHandler!
        oldInterruption()
        await settle()
        check(events == ["recording", "error"] && connections[0].invalidations == 1,
              "active service interruption must stop the session once")
        try await first.start(request("reconnected"))
        oldInterruption()
        await settle()
        first.stop()
        check(connections.count == 2 && connections[1].service.stops == ["reconnected"],
              "late interruption must not discard the replacement connection")
        first.cancel()

        connections[1].service.hold = true
        let pending = Task { try await first.start(request("pending")) }
        await settle()
        first.stop()
        check(connections[1].service.stops.last == "pending", "early stop must reach the starting recording")
        first.cancel()
        do { try await pending.value; fatalError("cancelled start succeeded") } catch is CancellationError {} catch { fatalError("wrong cancel error") }
        checks += 1
        connections[1].service.hold = false
        try await second.start(request("after-cancel"))
        connections[1].service.replies[1](true, "") // old pending reply
        await settle()
        second.stop()
        check(connections[1].service.stops.last == "after-cancel", "late start reply must not replace active session")
        second.cancel()

        connections[1].service.accept = false
        do { try await first.start(request("reject")); fatalError("rejection accepted") } catch {}
        check(connections[1].invalidations == 1, "rejected start must discard uncertain server state")
        try await second.start(request("after-reject"))
        second.cancel()
        check(connections.count == 3, "next start must recreate rejected connection")

        connections[2].service.hold = true
        let timeout = VoiceServiceBridge(channel: channel, startTimeout: .milliseconds(30))
        do { try await timeout.start(request("timeout")); fatalError("timeout accepted") } catch {}
        check(connections[2].invalidations == 1, "unanswered start must time out and discard connection")
        try await first.start(request("after-timeout"))
        connections[2].service.replies.last?(true, "")
        connections[2].service.replies.last?(false, "late duplicate")
        await settle()
        first.stop()
        check(connections.count == 4 && connections[3].service.stops.last == "after-timeout",
              "late duplicate replies must not resume a continuation twice")
        first.cancel()

        connections[3].service.hold = true
        let cancelled = Task { try await first.start(request("task-cancel")) }
        await settle()
        cancelled.cancel()
        do { try await cancelled.value; fatalError("task cancellation ignored") } catch is CancellationError {} catch { fatalError("wrong task cancel error") }
        check(connections[3].service.cancels.last == "task-cancel", "task cancellation must reach server")
        connections[3].service.hold = false
        try await second.start(request("after-task-cancel"))
        second.cancel()

        connections[3].service.hold = true
        let failed = Task { try await first.start(request("proxy-error")) }
        await settle()
        connections[3].proxyError?(NSError(domain: "test", code: 1))
        do { try await failed.value; fatalError("proxy error ignored") } catch {}
        check(connections[3].invalidations == 1, "proxy failure must discard connection")
        for index in 0..<50 {
            let bridge = VoiceServiceBridge(channel: channel)
            try await bridge.start(request("rapid-\(index)"))
            bridge.cancel()
        }
        check(connections.count == 5 && connections[4].invalidations == 0,
              "repeated sessions must not repeatedly invalidate or recreate XPC")
        let idleInterruption = connections[4].interruptionHandler!
        idleInterruption()
        await settle()
        try await second.start(request("after-idle-interruption"))
        second.cancel()
        check(connections.count == 6, "idle service interruption must recreate on next start")

        // Stop watchdog timeout: if server hangs after stop, bridge must time out and report error
        var stopWatchdogErrors: [String] = []
        let stopWatchdogBridge = VoiceServiceBridge(channel: channel, stopTimeout: .milliseconds(40))
        stopWatchdogBridge.onEvent = { if $0.kind == "error" { stopWatchdogErrors.append($0.text) } }
        try await stopWatchdogBridge.start(request("stop-watchdog"))
        channel.receive(try JSONEncoder().encode(VoiceEvent(sessionID: "stop-watchdog", kind: "recording")))
        await settle()
        stopWatchdogBridge.stop()
        try await Task.sleep(for: .milliseconds(70))
        check(stopWatchdogErrors == ["语音转写超时，请重试"], "stop watchdog must emit error when server hangs after stop")
        check(connections[5].invalidations == 1, "stop watchdog must discard hung connection")

        // Terminal event before timeout disarms stop watchdog
        var disarmedErrors: [String] = []
        let disarmedBridge = VoiceServiceBridge(channel: channel, stopTimeout: .milliseconds(50))
        disarmedBridge.onEvent = { if $0.kind == "error" { disarmedErrors.append($0.text) } }
        try await disarmedBridge.start(request("disarm-stop-watchdog"))
        channel.receive(try JSONEncoder().encode(VoiceEvent(sessionID: "disarm-stop-watchdog", kind: "recording")))
        await settle()
        disarmedBridge.stop()
        channel.receive(try JSONEncoder().encode(VoiceEvent(sessionID: "disarm-stop-watchdog", kind: "completed", text: "ok")))
        await settle()
        try await Task.sleep(for: .milliseconds(70))
        check(disarmedErrors.isEmpty, "completed event must disarm stop watchdog")
        disarmedBridge.cancel()

        print("PASS \(checks) bridge lifecycle checks; no service or microphone launched")
    }
}

import AIMEVoice
import AppKit
import Foundation
import OSLog

// One host connection outlives the per-recording bridge. Keeping an idle XPC
// connection does not start capture; launchd can still interrupt the service.
@MainActor
final class VoiceServiceChannel: NSObject, VoiceObserverProtocol {
    static let shared = VoiceServiceChannel()
    private let makeConnection: () -> NSXPCConnection
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var warmUpID: UUID?
    private var warmUpComplete = false
    private var voiceEnabled = true
    private var warmUpTimeout: Task<Void, Never>?
    private let warmUpDeadline: Duration
    weak var owner: VoiceServiceBridge?

    init(makeConnection: @escaping () -> NSXPCConnection = {
        NSXPCConnection(serviceName: Bundle.main.object(forInfoDictionaryKey: "AIMEVoiceServiceIdentifier") as? String
            ?? "app.zool.aime.voice")
    }, warmUpDeadline: Duration = .seconds(3)) {
        self.makeConnection = makeConnection
        self.warmUpDeadline = warmUpDeadline
        super.init()
    }

    func acquire(for bridge: VoiceServiceBridge) throws -> NSXPCConnection {
        guard owner == nil || owner === bridge else {
            throw VoiceBridgeError(message: "已有语音任务正在运行")
        }
        owner = bridge
        return connect()
    }

    // Fire-and-forget: never hold a recording owner or make start await warmup.
    // The capture service owns microphone permission; the host's TCC identity may differ.
    // Connecting XPC is harmless even when the service refuses audio graph warmup.
    func warmUpIfAuthorized(enabled: Bool) {
        voiceEnabled = enabled
        if !enabled {
            if owner == nil { discard() }
            return
        }
        guard enabled, owner == nil, !warmUpComplete, warmUpID == nil else { return }
        let channel = connect()
        let id = UUID()
        warmUpID = id
        warmUpTimeout = Task { @MainActor [weak self, warmUpDeadline] in
            do { try await Task.sleep(for: warmUpDeadline) } catch { return }
            self?.finishWarmUp(id, success: false, transportFailed: true)
        }
        guard let proxy = channel.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] _ in
            Task { @MainActor in self?.finishWarmUp(id, success: false, transportFailed: true) }
        }) as? any VoiceServiceProtocol else {
            finishWarmUp(id, success: false, transportFailed: true)
            return
        }
        proxy.warmUp { @Sendable [weak self] ready in
            Task { @MainActor in self?.finishWarmUp(id, success: ready) }
        }
    }

    private func finishWarmUp(_ id: UUID, success: Bool, transportFailed: Bool = false) {
        guard warmUpID == id else { return }
        warmUpID = nil
        warmUpTimeout?.cancel()
        warmUpTimeout = nil
        warmUpComplete = success
        // A delayed error must never invalidate a connection already in use.
        if transportFailed, owner == nil { discard() }
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let channel = makeConnection()
        let id = UUID()
        channel.remoteObjectInterface = NSXPCInterface(with: VoiceServiceProtocol.self)
        channel.exportedInterface = NSXPCInterface(with: VoiceObserverProtocol.self)
        channel.exportedObject = self
        channel.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.disconnect(id) }
        }
        channel.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.disconnect(id) }
        }
        connectionID = id
        connection = channel
        channel.resume()
        return channel
    }

    private func disconnect(_ id: UUID) {
        guard connectionID == id else { return }
        let bridge = owner
        discard()
        bridge?.serviceDisconnected()
    }

    // A failed/timed-out start has an uncertain server state: discard only that
    // owner's connection. Late callbacks from it cannot affect a newer session.
    func discard(for bridge: VoiceServiceBridge) {
        guard owner === bridge else { return }
        discard()
    }

    private func discard() {
        warmUpTimeout?.cancel()
        warmUpTimeout = nil
        warmUpID = nil
        warmUpComplete = false
        let old = connection
        connection = nil
        connectionID = nil
        owner = nil
        old?.invalidationHandler = nil
        old?.interruptionHandler = nil
        old?.invalidate()
    }

    func stop(for bridge: VoiceServiceBridge, sessionID: String) {
        guard owner === bridge else { return }
        (connection?.remoteObjectProxy as? any VoiceServiceProtocol)?.stop(sessionID)
    }

    func cancel(for bridge: VoiceServiceBridge, sessionID: String) {
        guard owner === bridge else { return }
        (connection?.remoteObjectProxy as? any VoiceServiceProtocol)?.cancel(sessionID)
        owner = nil
        if !voiceEnabled { discard() }
    }

    nonisolated func receive(_ data: Data) {
        guard let event = try? JSONDecoder().decode(VoiceEvent.self, from: data) else { return }
        Task { @MainActor in self.owner?.receive(event) }
    }
}

@MainActor
final class VoiceServiceBridge: NSObject {
    /// Call at host launch / voice-enable. Returns immediately, without prompting
    /// or capturing; unavailable services and revoked permission are safe no-ops.
    static func warmUpIfAuthorized(enabled: Bool) {
        VoiceServiceChannel.shared.warmUpIfAuthorized(enabled: enabled)
    }
    private static let logger = Logger(subsystem: "app.zool.aime.voice", category: "latency")
    private let channel: VoiceServiceChannel
    private let startTimeout: Duration
    private var sessionID: String?
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var pendingID: UUID?
    private var startupID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var startedAt: ContinuousClock.Instant?
    var onEvent: ((VoiceEvent) -> Void)?

    init(channel: VoiceServiceChannel = .shared, startTimeout: Duration = .seconds(3)) {
        self.channel = channel
        self.startTimeout = startTimeout
        super.init()
    }

    func start(_ request: VoiceRequest) async throws {
        try Task.checkCancellation()
        guard sessionID == nil else { throw VoiceBridgeError(message: "已有语音任务正在运行") }
        let payload = try JSONEncoder().encode(request)
        let begin = ContinuousClock.now
        let connection = try channel.acquire(for: self)
        sessionID = request.sessionID
        startedAt = begin
        let id = UUID()
        pendingID = id
        startupID = id
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingStart = continuation
                timeoutTask = Task { @MainActor [weak self, startTimeout] in
                    do { try await Task.sleep(for: startTimeout) } catch { return }
                    self?.failStart(id, error: VoiceBridgeError(message: "语音服务启动超时，请重试"))
                }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] _ in
                    Task { @MainActor in
                        self?.failStart(id, error: VoiceBridgeError(message: "无法连接语音服务"))
                    }
                }) as? any VoiceServiceProtocol else {
                    failStart(id, error: VoiceBridgeError(message: "无法连接语音服务"))
                    return
                }
                proxy.start(payload) { @Sendable [weak self] success, message in
                    Task { @MainActor in
                        guard let self, self.pendingID == id else { return }
                        if success { self.resolveStart(.success(())) }
                        else { self.failStart(id, error: VoiceBridgeError(message: message.isEmpty ? "无法连接语音服务" : message)) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == request.sessionID else { return }
                self.cancel()
            }
        }
        try Task.checkCancellation()
        guard sessionID == request.sessionID else { throw CancellationError() }
    }

    private func resolveStart(_ result: Result<Void, any Error>) {
        let continuation = pendingStart
        pendingStart = nil
        pendingID = nil
        // Acceptance is not recorder readiness. Keep the original deadline
        // until both the reply and the recording event have arrived.
        switch result {
        case .failure: finishStartup()
        case .success: if startedAt == nil { finishStartup() }
        }
        continuation?.resume(with: result)
    }

    private func finishStartup() {
        startupID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func failStart(_ id: UUID, error: any Error) {
        guard startupID == id else { return }
        let accepted = pendingStart == nil
        let failedSessionID = sessionID
        channel.discard(for: self)
        sessionID = nil
        startedAt = nil
        resolveStart(.failure(error))
        if accepted, let failedSessionID {
            onEvent?(VoiceEvent(sessionID: failedSessionID, kind: "error", text: error.localizedDescription))
        }
    }

    func stop() {
        guard let sessionID else { return }
        channel.stop(for: self, sessionID: sessionID)
    }

    fileprivate func serviceDisconnected() {
        guard let sessionID else { return }
        self.sessionID = nil
        startedAt = nil
        resolveStart(.failure(VoiceBridgeError(message: "语音服务连接已中断，请重试")))
        onEvent?(VoiceEvent(sessionID: sessionID, kind: "error", text: "语音服务连接已中断，请重试"))
    }

    func cancel() {
        if let sessionID { channel.cancel(for: self, sessionID: sessionID) }
        sessionID = nil
        startedAt = nil
        resolveStart(.failure(CancellationError()))
        onEvent = nil
    }

    fileprivate func receive(_ event: VoiceEvent) {
        guard sessionID == event.sessionID else { return }
        if event.kind == "recording", let startedAt {
            let elapsed = startedAt.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            Self.logger.notice("stage=xpcToRecordingEvent startupMs=\(ms)")
            self.startedAt = nil
            if pendingStart == nil { finishStartup() }
        }
        onEvent?(event)
    }
}

private struct VoiceBridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

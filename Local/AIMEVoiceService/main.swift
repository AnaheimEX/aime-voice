import AIMEVoice
import Darwin
import Foundation
import XPC

// XPC normally ends its transaction as soon as start/warmUp replies. Keep the
// service's prewarmed framework alive while the input method owns a connection.
// This transaction does not open a microphone or prevent system sleep.
private final class CaptureServiceLifetime {
    init() { xpc_transaction_begin() }
    deinit { xpc_transaction_end() }
}

@MainActor
final class VoiceSession: NSObject, VoiceServiceProtocol {
    private let runtime: VoiceRuntime
    private var lifetime: CaptureServiceLifetime? = CaptureServiceLifetime()

    init(connection: NSXPCConnection) {
        runtime = VoiceRuntime { [weak connection] event in
            guard let observer = connection?.remoteObjectProxy as? any VoiceObserverProtocol,
                  let data = try? JSONEncoder().encode(event) else { return }
            observer.receive(data)
        }
    }

    nonisolated func ping(_ reply: @escaping () -> Void) { reply() }

    nonisolated func warmUp(_ reply: @escaping (Bool) -> Void) {
        nonisolated(unsafe) let response = reply
        Task { @MainActor in response(await self.runtime.warmUp()) }
    }

    nonisolated func start(_ data: Data, reply: @escaping (Bool, String) -> Void) {
        nonisolated(unsafe) let response = reply
        Task { @MainActor in
            let request: VoiceRequest
            do { request = try JSONDecoder().decode(VoiceRequest.self, from: data) }
            catch { response(false, "语音请求格式无效"); return }
            do { try self.runtime.start(request); response(true, "") }
            catch { response(false, error.localizedDescription) }
        }
    }

    nonisolated func stop(_ sessionID: String) {
        Task { @MainActor in self.runtime.stop(sessionID) }
    }

    nonisolated func cancel(_ sessionID: String) {
        Task { @MainActor in self.runtime.cancel(sessionID) }
    }

    func disconnect() {
        runtime.shutdown()
        lifetime = nil
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        nonisolated(unsafe) let channel = connection
        Task { @MainActor in
            let session = VoiceSession(connection: channel)
            channel.exportedInterface = NSXPCInterface(with: VoiceServiceProtocol.self)
            channel.remoteObjectInterface = NSXPCInterface(with: VoiceObserverProtocol.self)
            channel.exportedObject = session
            channel.invalidationHandler = { @Sendable in Task { @MainActor in session.disconnect() } }
            channel.interruptionHandler = { @Sendable in Task { @MainActor in session.disconnect() } }
            channel.resume()
        }
        return true
    }
}

// The host IME owns this service. launchd manages its lifetime and XPC endpoint.
let listener = NSXPCListener.service()
let listenerDelegate = ListenerDelegate()
listener.delegate = listenerDelegate
listener.resume()

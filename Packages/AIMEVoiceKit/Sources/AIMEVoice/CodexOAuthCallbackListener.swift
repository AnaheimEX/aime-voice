import Foundation
import Network

/// One short-lived, loopback-only OAuth callback listener per explicit login.
actor CodexOAuthCallbackListener {
    struct Authorization: Sendable {
        let code: String
        let clientID: String?
    }
    nonisolated let redirectURI: String
    private let listener: NWListener
    private let expectedState: String
    private let queue = DispatchQueue(label: "app.zool.aime.chatgpt-oauth")
    private var ready: CheckedContinuation<Void, any Error>?
    private var response: CheckedContinuation<Authorization, any Error>?
    private var result: Result<Authorization, any Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var timeout: Task<Void, Never>?

    private init(listener: NWListener, state: String, port: UInt16) {
        self.listener = listener
        expectedState = state
        redirectURI = "http://127.0.0.1:\(port)/auth/callback"
    }

    static func start(state: String) async throws -> CodexOAuthCallbackListener {
        // Bind a random unprivileged port directly to IPv4 loopback. Binding before
        // returning the authorization URL prevents another process taking the port.
        for _ in 0..<12 {
            let port = UInt16.random(in: 49152...65535)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = false
            guard let listener = try? NWListener(using: parameters) else { continue }
            let server = CodexOAuthCallbackListener(listener: listener, state: state, port: port)
            do { try await server.listen(); return server } catch { await server.cancel() }
        }
        throw CodexSubscriptionClient.Failure.loginFailed
    }

    private func listen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { state in Task { await self.stateChanged(state) } }
            listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
            listener.start(queue: queue)
        }
        timeout = Task {
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self.finish(.failure(CodexSubscriptionClient.Failure.timedOut))
            self.listener.cancel()
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            ready?.resume(); ready = nil
        case .failed:
            ready?.resume(throwing: CodexSubscriptionClient.Failure.loginFailed); ready = nil
            finish(.failure(CodexSubscriptionClient.Failure.loginFailed))
        case .cancelled:
            ready?.resume(throwing: CancellationError()); ready = nil
        default: break
        }
    }

    func authorization() async throws -> Authorization {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { response = $0 }
    }

    func cancel() {
        timeout?.cancel(); timeout = nil
        listener.cancel()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        ready?.resume(throwing: CancellationError()); ready = nil
        finish(.failure(CancellationError()))
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); buffers.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        buffers[id] = Data()
        connection.start(queue: queue)
        receive(id, connection: connection)
    }

    private func receive(_ id: UUID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            Task { await self.received(id, data: data, complete: complete, failed: error != nil) }
        }
    }

    private func received(_ id: UUID, data: Data?, complete: Bool, failed: Bool) {
        guard let connection = connections[id] else { return }
        if let data { buffers[id, default: Data()].append(data) }
        guard let buffer = buffers[id], buffer.count <= 16_384 else { close(id); return }
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)),
           let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) {
            handle(header, id: id)
        } else if complete || failed { close(id) }
        else { receive(id, connection: connection) }
    }

    private func handle(_ header: String, id: UUID) {
        guard let first = header.components(separatedBy: "\r\n").first else { close(id); return }
        let request = first.split(separator: " ")
        guard request.count == 3, request[0] == "GET",
              let components = URLComponents(string: String(request[1])),
              components.scheme == nil, components.host == nil,
              components.path == "/auth/callback", let query = components.queryItems else {
            reply(id, code: 404, message: "此地址仅用于本次 ChatGPT 登录"); return
        }
        var parameters: [String: String] = [:]
        for item in query {
            guard parameters[item.name] == nil, let value = item.value else {
                reply(id, code: 400, message: "无效登录回调"); return
            }
            parameters[item.name] = value
        }
        guard parameters["state"] == expectedState else {
            reply(id, code: 400, message: "登录校验失败，请返回 AIME 重新登录"); return
        }
        if parameters["error"] != nil {
            reply(id, code: 200, message: "登录未完成，请返回 AIME")
            finish(.failure(CodexSubscriptionClient.Failure.denied))
            listener.cancel()
            return
        }
        guard let code = parameters["code"], !code.isEmpty else {
            reply(id, code: 400, message: "缺少授权码，请重新登录"); return
        }
        reply(id, code: 200, message: "已收到授权，请返回 AIME 查看登录结果。此窗口可以关闭")
        finish(.success(Authorization(code: code, clientID: parameters["client_id"])))
        listener.cancel()
    }

    private func reply(_ id: UUID, code: Int, message: String) {
        guard let connection = connections[id] else { return }
        let body = Data("<!doctype html><meta charset=\"utf-8\"><title>AIME</title><p>\(message)</p>".utf8)
        let header = Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in
            Task { await self.close(id) }
        })
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        buffers[id] = nil
    }

    private func finish(_ value: Result<Authorization, any Error>) {
        guard result == nil else { return }
        result = value
        timeout?.cancel(); timeout = nil
        response?.resume(with: value); response = nil
    }
}

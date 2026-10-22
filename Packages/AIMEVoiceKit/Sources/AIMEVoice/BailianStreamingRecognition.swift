import Foundation

/// DashScope run-task duplex ASR, adapted from Type4Me's BailianProtocol.
/// The older Qwen realtime protocol uses a different endpoint and is not interchangeable.
@MainActor
final class BailianStreamingRecognition {
    private let endpoint: VoiceEndpoint
    private let onPartial: @Sendable (String) -> Void
    private let taskID = UUID().uuidString
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var ready: Result<Void, any Error>?
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var terminal: Result<String, any Error>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var pending = Data()
    private var segments: [(id: String, text: String)] = []
    private var cancelled = false

    init(endpoint: VoiceEndpoint, onPartial: @escaping @Sendable (String) -> Void) {
        self.endpoint = endpoint
        self.onPartial = onPartial
    }

    func start() async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "wss", url.host != nil, url.path == "/api-ws/v1/inference",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !key.isEmpty, !model.isEmpty, !key.contains("\r"), !key.contains("\n") else {
            throw VoiceRecognitionError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 360
        let session = URLSession(configuration: configuration, delegate: VoiceASRNoRedirect(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, !self.cancelled else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw VoiceRecognitionError.invalidResponse
                    }
                    try self.receive(data)
                    if self.terminal != nil { return }
                }
            } catch {
                guard let self, !self.cancelled else { return }
                let error: any Error = error as? BailianFailure ?? error as? VoiceRecognitionError ?? VoiceRecognitionError.recognitionFailed
                self.complete(.failure(error))
            }
        }
        armTimeout(seconds: 20)
        do {
            try await send(action: "run-task", payload: [
                "task_group": "audio", "task": "asr", "function": "recognition", "model": model,
                "parameters": ["format": "pcm", "sample_rate": 16000], "input": [:]
            ])
            if let ready { try ready.get() } else {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { readyWaiter = $0 }
                } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
            }
            timer?.cancel(); timer = nil
            try Task.checkCancellation()
        } catch {
            cancel()
            throw error
        }
    }

    func append(_ pcm: Data) async throws {
        guard !cancelled else { throw CancellationError() }
        if let terminal { _ = try terminal.get(); return }
        guard let socket else { throw VoiceRecognitionError.invalidConfiguration }
        pending.append(pcm)
        // 100 ms 16 kHz mono signed 16-bit PCM frames, same format as Type4Me.
        while pending.count >= 3_200 {
            let packet = Data(pending.prefix(3_200))
            pending.removeFirst(3_200)
            try await socket.send(.data(packet))
        }
    }

    func finish() async throws -> String {
        defer { release() }
        guard !cancelled else { throw CancellationError() }
        if let terminal { return try terminal.get() }
        guard let socket else { throw VoiceRecognitionError.invalidConfiguration }
        if !pending.isEmpty { try await socket.send(.data(pending)); pending.removeAll() }
        try await send(action: "finish-task", payload: ["input": [:]])
        if let terminal { return try terminal.get() }
        armTimeout(seconds: 25)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() {
        cancelled = true
        complete(.failure(CancellationError()))
        release()
    }

    private func send(action: String, payload: [String: Any]) async throws {
        guard let socket else { throw VoiceRecognitionError.invalidConfiguration }
        let data = try JSONSerialization.data(withJSONObject: [
            "header": ["action": action, "task_id": taskID, "streaming": "duplex"], "payload": payload
        ])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any], let event = header["event"] as? String else {
            throw VoiceRecognitionError.invalidResponse
        }
        if let id = header["task_id"] as? String, id.lowercased() != taskID.lowercased() { throw VoiceRecognitionError.invalidResponse }
        switch event {
        case "task-started":
            ready = .success(())
            readyWaiter?.resume(); readyWaiter = nil
        case "task-failed":
            // Only expose the machine-readable error code, not server messages echoing user data.
            let raw = header["error_code"] as? String ?? "Unknown"
            let code = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" }.prefix(80).map(Character.init))
            throw BailianFailure.rejected(code)
        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  sentence["heartbeat"] as? Bool != true,
                  let text = sentence["text"] as? String else { return }
            let id = (sentence["sentence_id"] as? NSNumber)?.stringValue
                ?? (sentence["begin_time"] as? NSNumber)?.stringValue ?? "segment-\(segments.count)"
            if sentence["sentence_end"] as? Bool == true {
                if let index = segments.firstIndex(where: { $0.id == id }) { segments[index].text = text }
                else { segments.append((id: id, text: text)) }
                onPartial(Self.join(segments.map(\.text)))
            } else { onPartial(Self.join(segments.map(\.text)) + text) }
        case "task-finished":
            let text = Self.join(segments.map(\.text)).trimmingCharacters(in: .whitespacesAndNewlines)
            complete(text.isEmpty ? .failure(VoiceTranscriptionError.emptyTranscript) : .success(text))
        default: break
        }
    }

    private static func join(_ segments: [String]) -> String {
        segments.reduce(into: "") { output, segment in
            if let last = output.last, let first = segment.first,
               !last.isWhitespace, !first.isWhitespace,
               last.isASCII, first.isASCII, first.isLetter || first.isNumber {
                output += " "
            }
            output += segment
        }
    }

    private func armTimeout(seconds: Int) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.complete(.failure(VoiceRecognitionError.timedOut))
            self?.release()
        }
    }

    private func complete(_ result: Result<String, any Error>) {
        guard terminal == nil else { return }
        terminal = result
        if ready == nil {
            switch result {
            case .failure(let error): ready = .failure(error); readyWaiter?.resume(throwing: error)
            case .success: ready = .failure(VoiceRecognitionError.invalidResponse); readyWaiter?.resume(throwing: VoiceRecognitionError.invalidResponse)
            }
            readyWaiter = nil
        }
        waiter?.resume(with: result); waiter = nil
    }

    private func release() {
        timer?.cancel(); timer = nil
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

private enum BailianFailure: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        switch self { case .rejected(let code): "阿里百炼语音识别失败（\(code)），请检查模型、密钥、地域和额度" }
    }
}

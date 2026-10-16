import Foundation

/// Official v3 SAUC framing, using documented uncompressed request/response payloads.
@MainActor
final class VolcStreamingRecognition {
    private let endpoint: VoiceEndpoint
    private let languageHint: String
    private let hotwords: [String]
    private let secondPass: Bool?
    private let onPartial: @Sendable (String) -> Void
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var pending = Data()
    private var latestText = ""
    private var terminal: Result<String, any Error>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false
    // Vendor recommends 100–200 ms packets. Use the lower bound so the first
    // captured audio does not wait for an additional 100 ms of local batching.
    private static let packetBytes = 3_200 // 100 ms, 16 kHz mono Int16

    init(endpoint: VoiceEndpoint, language: String, hotwords: [String] = [], secondPass: Bool? = nil,
         onPartial: @escaping @Sendable (String) -> Void) {
        self.endpoint = endpoint
        // Only bigmodel_nostream accepts an explicit audio.language parameter.
        // The standard/async streaming APIs use their service language detection.
        self.languageHint = language
        self.hotwords = hotwords
        self.secondPass = secondPass
        self.onPartial = onPartial
    }

    static func connectionRequest(endpoint: VoiceEndpoint) throws -> URLRequest {
        let apiKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceID = endpoint.resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = endpoint.speechAuthMode == "legacy"
        let appID = legacy ? endpoint.appID.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard let url = URL(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "wss", url.host == "openspeech.bytedance.com",
              ["/api/v3/sauc/bigmodel", "/api/v3/sauc/bigmodel_async", "/api/v3/sauc/bigmodel_nostream"].contains(url.path),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !apiKey.isEmpty, !resourceID.isEmpty,
              endpoint.speechAuthMode == "api-key" || legacy, !legacy || !appID.isEmpty,
              ![apiKey, appID, resourceID].contains(where: { $0.contains("\r") || $0.contains("\n") }) else {
            throw VoiceRecognitionError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        let requestID = UUID().uuidString
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        if !legacy {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Access-Key")
        }
        return request
    }

    func start() async throws {
        let request = try Self.connectionRequest(endpoint: endpoint)
        guard let url = request.url else { throw VoiceRecognitionError.invalidConfiguration }
        let terms = VoiceVocabulary.streamingHotwords(hotwords)
        guard secondPass != false || url.path == "/api/v3/sauc/bigmodel_async" else {
            throw VoiceRecognitionError.invalidConfiguration
        }
        var recognitionRequest: [String: Any] = [
            "model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
            "enable_ddc": true, "enable_nonstream": secondPass ?? true,
            "show_utterances": true, "result_type": "full",
        ]
        if let context = try VoiceVocabulary.corpusContext(terms) {
            recognitionRequest["corpus"] = ["context": context]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 360
        let session = URLSession(configuration: configuration, delegate: VoiceASRNoRedirect(), delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        var audio: [String: Any] = ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1]
        if url.path.hasSuffix("bigmodel_nostream"), !languageHint.isEmpty, languageHint != "auto" {
            audio["language"] = languageHint == "zh" ? "zh-CN" : languageHint
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": UUID().uuidString],
            "audio": audio,
            "request": recognitionRequest,
        ])
        do { try await socket.send(.data(Self.packet(type: 1, flags: 0, serialization: 1, payload: body))) }
        catch {
            let failure = Self.transportFailure(error, response: socket.response)
            cancel()
            try Task.checkCancellation()
            throw failure
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        receiver = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, !self.cancelled else { return }
                    guard case .data(let data) = message else { throw VoiceRecognitionError.invalidResponse }
                    let response = try Self.decode(data)
                    if !response.text.isEmpty, response.text != self.latestText {
                        self.latestText = response.text
                        self.onPartial(response.text)
                    }
                    if response.final {
                        let text = self.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.complete(text.isEmpty ? .failure(VoiceTranscriptionError.emptyTranscript) : .success(text))
                        return
                    }
                }
            } catch {
                guard let self, !self.cancelled else { return }
                let safeError = Self.transportFailure(error, response: socket.response)
                self.complete(.failure(safeError))
            }
        }
    }

    func append(_ pcm: Data) async throws {
        guard !cancelled else { throw CancellationError() }
        if let terminal { _ = try terminal.get(); return }
        guard let socket else { throw VoiceRecognitionError.invalidConfiguration }
        pending.append(pcm)
        while pending.count >= Self.packetBytes {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            if let terminal { _ = try terminal.get(); return }
            let packet = Data(pending.prefix(Self.packetBytes))
            pending.removeFirst(Self.packetBytes)
            do { try await socket.send(.data(Self.packet(type: 2, flags: 0, serialization: 0, payload: packet))) }
            catch { try Task.checkCancellation(); throw Self.transportFailure(error, response: socket.response) }
        }
    }

    func finish() async throws -> String {
        defer { releaseTransport() }
        guard !cancelled else { throw CancellationError() }
        if let terminal { return try terminal.get() }
        guard let socket else { throw VoiceRecognitionError.invalidConfiguration }
        // The final remainder may be shorter than 100 ms, including a short recording.
        // Always send the negative/final packet and wait for an authoritative response.
        do { try await socket.send(.data(Self.packet(type: 2, flags: 2, serialization: 0, payload: pending))) }
        catch { try Task.checkCancellation(); throw Self.transportFailure(error, response: socket.response) }
        pending.removeAll(keepingCapacity: false)
        if let terminal { return try terminal.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.complete(.failure(VoiceRecognitionError.timedOut))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() {
        cancelled = true
        complete(.failure(CancellationError()))
        releaseTransport()
        pending.removeAll(keepingCapacity: false)
    }

    private func complete(_ result: Result<String, any Error>) {
        guard terminal == nil else { return }
        terminal = result
        timeout?.cancel()
        timeout = nil
        waiter?.resume(with: result)
        waiter = nil
    }

    private func releaseTransport() {
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        timeout?.cancel()
        timeout = nil
    }

    static func transportFailure(_ error: any Error, response: URLResponse?) -> VoiceRecognitionError {
        if let failure = error as? VoiceRecognitionError { return failure }
        if let response = response as? HTTPURLResponse, response.statusCode >= 300 {
            return .speechHTTPStatus(response.statusCode)
        }
        return .recognitionFailed
    }

    private static func packet(type: UInt8, flags: UInt8, serialization: UInt8, payload: Data) -> Data {
        var data = Data([0x11, (type << 4) | flags, serialization << 4, 0])
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private static func decode(_ data: Data) throws -> (text: String, final: Bool) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] >> 4 == 1 else { throw VoiceRecognitionError.invalidResponse }
        let headerBytes = Int(bytes[0] & 15) * 4
        let type = bytes[1] >> 4
        let flags = bytes[1] & 15
        var offset = headerBytes
        func word(_ index: Int) throws -> UInt32 {
            guard index >= 4, bytes.count >= index + 4 else { throw VoiceRecognitionError.invalidResponse }
            return (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16)
                | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
        }
        guard headerBytes >= 4, bytes.count >= headerBytes else { throw VoiceRecognitionError.invalidResponse }
        if type == 15 { throw VoiceRecognitionError.serverCode(Int(try word(offset))) }
        guard type == 9, bytes[2] >> 4 == 1, bytes[2] & 15 == 0 else {
            // The documented server uses the client's requested compression (none).
            throw VoiceRecognitionError.invalidResponse
        }
        if flags & 1 != 0 { offset += 4 }
        let size = Int(try word(offset))
        offset += 4
        guard size <= 4_194_304, bytes.count >= offset + size,
              let json = try JSONSerialization.jsonObject(with: Data(bytes[offset..<offset + size])) as? [String: Any] else {
            throw VoiceRecognitionError.invalidResponse
        }
        let result = json["result"] as? [String: Any]
        // Match Type4Me's canonical snapshot semantics (MIT, see
        // licenses/type4me.LICENSE.txt): revisions replace previous hypotheses.
        // Some responses carry utterances without a canonical text field. Join
        // those directly, never inject spaces based on the speaker's pauses.
        let canonical = (result?["text"] as? String ?? json["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let utterances = result?["utterances"] as? [[String: Any]]
            ?? json["utterances"] as? [[String: Any]] ?? []
        let text = canonical.isEmpty
            ? utterances.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : canonical
        // Type4Me additionally handles async-optimized final flag 4.
        return (text, flags == 2 || flags == 3 || flags == 4)
    }
}

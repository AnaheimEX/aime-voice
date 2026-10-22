public import Foundation

public enum VoiceTranscriptionError: LocalizedError, Sendable {
    case invalidConfiguration, emptyRecording, tooLong, invalidResponse, httpStatus(Int), emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "请填写语音识别服务的 HTTP API 地址和模型 ID"
        case .emptyRecording: "录音过短或没有录到声音"
        case .tooLong: "单次录音不能超过 5 分钟"
        case .invalidResponse: "语音识别服务返回了无法解析的响应"
        case .httpStatus(let status): "语音识别请求失败（HTTP \(status)）"
        case .emptyTranscript: "语音识别服务没有返回文字"
        }
    }
}

public struct VoiceTranscriber: Sendable {
    // Reuse connections without persisting cookies or forwarding recordings on redirects.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: VoiceASRNoRedirect(), delegateQueue: nil)
    }()
    public init() {}

    public func transcribe(_ audio: RecordedAudio, settings: VoiceSettings, hotwords: [String]? = nil) async throws -> String {
        try Task.checkCancellation()
        guard audio.duration.isFinite, audio.duration >= 0.1, audio.wav.count > 44 else {
            throw VoiceTranscriptionError.emptyRecording
        }
        guard audio.duration <= 300, audio.wav.count <= 9_600_044 else {
            throw VoiceTranscriptionError.tooLong
        }
        if settings.asr.resolvedProtocol == .fishASR {
            return try await FishSpeechTranscription.transcribe(audio, endpoint: settings.asr)
        }
        if settings.asr.resolvedProtocol == .mimoASR {
            return try await MiMoSpeechTranscription.transcribe(audio, settings: settings)
        }
        if settings.asr.resolvedProtocol == .volcFlash {
            return try await Self.volcFlash(audio, endpoint: settings.asr, hotwords: hotwords ?? settings.vocabulary.selectedHotwords(for: settings.asr))
        }
        let model = settings.asr.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !model.contains("\r"), !model.contains("\n"),
              let url = Self.endpoint(settings.asr.baseURL) else {
            throw VoiceTranscriptionError.invalidConfiguration
        }
        let boundary = "AIME-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model)
        field("response_format", "json")
        let language = settings.language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.contains("\r"), !language.contains("\n") else { throw VoiceTranscriptionError.invalidConfiguration }
        if !language.isEmpty && language != "auto" { field("language", language) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio.wav)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = settings.asr.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains("\r"), !key.contains("\n") else { throw VoiceTranscriptionError.invalidConfiguration }
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw VoiceTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceTranscriptionError.httpStatus(http.statusCode)
        }
        struct Transcription: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Transcription.self, from: data) else {
            throw VoiceTranscriptionError.invalidResponse
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
        return text
    }

    static func volcFlashRequest(_ audio: RecordedAudio, endpoint: VoiceEndpoint, hotwords: [String]) throws -> URLRequest {
        let apiKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceID = endpoint.resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = endpoint.speechAuthMode == "legacy"
        let appID = legacy ? endpoint.appID.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard let url = URL(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "openspeech.bytedance.com",
              url.path == "/api/v3/auc/bigmodel/recognize/flash", url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil,
              !apiKey.isEmpty, !resourceID.isEmpty,
              endpoint.speechAuthMode == "api-key" || legacy, !legacy || !appID.isEmpty,
              ![apiKey, appID, resourceID].contains(where: { $0.contains("\r") || $0.contains("\n") }) else {
            throw VoiceRecognitionError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        if !legacy {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Access-Key")
        }
        var recognitionRequest: [String: Any] = ["model_name": "bigmodel"]
        if let context = try VoiceVocabulary.corpusContext(Array(hotwords.prefix(500))) {
            recognitionRequest["corpus"] = ["context": context]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": UUID().uuidString],
            "audio": ["data": audio.wav.base64EncodedString()],
            "request": recognitionRequest,
        ])
        return request
    }

    private static func volcFlash(_ audio: RecordedAudio, endpoint: VoiceEndpoint, hotwords: [String]) async throws -> String {
        let request = try volcFlashRequest(audio, endpoint: endpoint, hotwords: hotwords)
        let session = URLSession(configuration: .ephemeral, delegate: VoiceASRNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw VoiceRecognitionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw VoiceRecognitionError.speechHTTPStatus(http.statusCode) }
        guard let codeText = http.value(forHTTPHeaderField: "X-Api-Status-Code"), let code = Int(codeText) else {
            throw VoiceRecognitionError.invalidResponse
        }
        if code == 20_000_003 { throw VoiceTranscriptionError.emptyTranscript }
        guard code == 20_000_000 else { throw VoiceRecognitionError.serverCode(code) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any], let raw = result["text"] as? String else {
            throw VoiceRecognitionError.invalidResponse
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
        return text
    }

    private static func endpoint(_ value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") {
            if path.isEmpty { path = "/v1" }
            path += "/audio/transcriptions"
        }
        components.path = path
        return components.url
    }
}

final class VoiceASRNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

import Foundation

/// Native Fish STT: complete WAV upload, model header, one final transcript.
enum FishSpeechTranscription {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: VoiceASRNoRedirect(), delegateQueue: nil)
    }()

    static func transcribe(_ audio: RecordedAudio, endpoint: VoiceEndpoint) async throws -> String {
        let endpoint = endpoint.normalizedFishASR
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["transcribe-1-pro", "transcribe-1"].contains(model) else { throw Failure.model }
        guard !key.isEmpty, !key.contains("\r"), !key.contains("\n"),
              var url = URLComponents(string: endpoint.baseURL),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              (url.scheme == "https" && host == "api.fish.audio")
                || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw VoiceTranscriptionError.invalidConfiguration
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard ["v1/asr", "v1", "compat/v1", "compat/v1/audio/transcriptions"].contains(path) else {
            throw VoiceTranscriptionError.invalidConfiguration
        }
        url.path = "/v1/asr"
        guard let address = url.url else { throw VoiceTranscriptionError.invalidConfiguration }
        let boundary = "AIME-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(contentsOf: text.utf8) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("ignore_timestamps", "true")
        if model == "transcribe-1-pro" {
            field("tag_audio_events", "false")
            field("diarize", "false")
        }
        // Omit language for automatic detection; no undocumented hotword fields.
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio.wav)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(model, forHTTPHeaderField: "model")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw VoiceTranscriptionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        struct Result: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw VoiceTranscriptionError.invalidResponse
        }
        // diarize=false suppresses structured turns, not inline speaker markers.
        let text = result.text.replacingOccurrences(of: #"<\|speaker:[0-9]+\|>\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
        return text
    }

    enum Failure: LocalizedError {
        case model, http(Int)
        var errorDescription: String? {
            switch self {
            case .model: "Fish原生识别请选择transcribe-1-pro或transcribe-1"
            case .http(401), .http(403): "Fish语音鉴权失败，请检查Fish API Key及账号权限"
            case .http(402): "Fish API余额不足，请在开发者后台查看API余额；API余额与网页平台积分独立"
            case .http(429): "Fish语音并发请求过多，请稍后重试"
            case .http(400), .http(413), .http(415): "Fish拒绝音频请求，请检查音频格式、大小及模型参数"
            case .http(let status): "Fish语音识别失败（HTTP \(status)），请稍后重试"
            }
        }
    }
}

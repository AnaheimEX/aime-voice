import Foundation

/// Run only the STT task; AIME owns all subsequent text processing.
enum InterfazeSpeechTranscription {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func validate(apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else {
            throw VoiceTranscriptionError.invalidConfiguration
        }
    }

    static func transcribe(_ audio: RecordedAudio, apiKey: String) async throws -> String {
        try validate(apiKey: apiKey)
        guard audio.duration.isFinite, audio.duration >= 0.1, audio.duration <= 300,
              !audio.wav.isEmpty, audio.wav.count <= 9_600_044 else { throw Failure.audio }
        let body: [String: Any] = [
            "model": "interfaze-1",
            "stream": false,
            "messages": [
                ["role": "system", "content": "<task>speech_to_text</task>"],
                ["role": "user", "content": [
                    ["type": "file", "file": ["filename": "speech.wav",
                        "file_data": "data:audio/wav;base64," + audio.wav.base64EncodedString()]],
                ]],
            ],
            "response_format": ["type": "json_schema", "json_schema": [
                "name": "stt_task", "schema": [String: String](),
            ]],
        ]
        var request = URLRequest(url: URL(string: "https://api.interfaze.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-interfaze-zdr")
        request.setValue("true", forHTTPHeaderField: "x-interfaze-bypass-cache")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw VoiceTranscriptionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> String {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
                let finish_reason: String
            }
            let choices: [Choice]
        }
        struct Output: Decodable {
            struct Result: Decodable { let text: String }
            let name: String
            let result: Result
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = completion.choices.first, choice.finish_reason == "stop",
              let output = try? JSONDecoder().decode(Output.self, from: Data(choice.message.content.utf8)),
              output.name == "speech_to_text" else { throw VoiceTranscriptionError.invalidResponse }
        let text = output.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
        return text
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    enum Failure: LocalizedError {
        case audio, http(Int)
        var errorDescription: String? {
            switch self {
            case .audio: "Interfaze 音频为空、过大或超出五分钟限制"
            case .http(401), .http(403): "Interfaze 鉴权失败，请检查 API Key 和账户权限"
            case .http(402): "Interfaze 账户额度不足"
            case .http(429): "Interfaze 请求受到限流，请稍后重试"
            case .http(let status): "Interfaze 语音识别失败（HTTP \(status)）"
            }
        }
    }
}

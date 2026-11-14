import Foundation

/// MiMo accepts one complete WAV via chat/completions, not audio/transcriptions.
/// Request layout follows Type4Me's MiMoASRProtocol and Xiaomi's ASR API.
enum MiMoSpeechTranscription {
    static func transcribe(_ audio: RecordedAudio, settings: VoiceSettings) async throws -> String {
        let endpoint = settings.asr
        guard !endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceRecognitionError.invalidConfiguration
        }
        let dataURL = "data:audio/wav;base64," + audio.wav.base64EncodedString()
        guard dataURL.utf8.count <= 10 * 1024 * 1024 else { throw Failure.tooLarge }
        let language = settings.language.lowercased().split(separator: "-").first.map(String.init) ?? "auto"
        let body = try JSONSerialization.data(withJSONObject: [
            "model": endpoint.model,
            "messages": [["role": "user", "content": [[
                "type": "input_audio", "input_audio": ["data": dataURL, "format": "wav"]
            ]]]],
            "asr_options": ["language": ["zh", "en"].contains(language) ? language : "auto"],
            "stream": false
        ])
        let data: Data
        do {
            data = try await VoiceHTTP.request(endpoint: endpoint, path: "chat/completions", body: body, timeout: 120)
        } catch let error as URLError where error.code == .timedOut {
            throw VoiceTranscriptionError.timedOut
        }
        try Task.checkCancellation()
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              let choice = result.choices.first else { throw VoiceTranscriptionError.invalidResponse }
        guard choice.finish_reason == "stop" else { throw Failure.incomplete }
        let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
        return text
    }

    private enum Failure: LocalizedError {
        case tooLarge, incomplete
        var errorDescription: String? {
            switch self {
            case .tooLarge: "录音超过 MiMo 单次音频大小限制，请缩短录音后重试"
            case .incomplete: "MiMo 未完整返回识别结果，请检查模型配置或缩短录音后重试"
            }
        }
    }
}

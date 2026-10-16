import Foundation

private final class HTTPMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VoiceHTTP.Metrics] = []

    func record(_ metrics: VoiceHTTP.Metrics) {
        lock.withLock { values.append(metrics) }
    }

    var metrics: [VoiceHTTP.Metrics] { lock.withLock { values } }
}

@main
struct VoiceProviderCheck {
    // Reject strings and Foundation objects: telemetry contains only numeric
    // durations, booleans, and their optional/array/struct containers.
    static func requireSafeMetrics(_ value: Any) throws {
        if value is Double || value is Bool { return }
        let mirror = Mirror(reflecting: value)
        try require([.struct, .collection, .optional].contains(mirror.displayStyle), "metrics exposed a non-timing value")
        for child in mirror.children { try requireSafeMetrics(child.value) }
    }

    private static func collected(_ recorder: HTTPMetricsRecorder) async throws -> VoiceHTTP.Metrics {
        for _ in 0..<100 {
            if !recorder.metrics.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let values = recorder.metrics
        try require(values.count == 1, "expected exactly one metrics callback")
        let metrics = values[0]
        try requireSafeMetrics(metrics)
        try require(metrics.totalDuration.isFinite && metrics.totalDuration >= 0, "invalid total duration")
        try require(metrics.transactions.count == 1, "unexpected transaction count")
        let transaction = metrics.transactions[0]
        for duration in [transaction.dnsDuration, transaction.tcpDuration, transaction.tlsDuration,
                         transaction.responseWaitDuration, transaction.downloadDuration].compactMap({ $0 }) {
            try require(duration.isFinite && duration >= 0 && duration <= metrics.totalDuration + 0.01,
                        "invalid phase duration")
        }
        return metrics
    }

    @MainActor static func checkHTTPMetrics(endpoint: VoiceEndpoint) async throws {
        var endpoint = endpoint
        endpoint.apiKey = "synthetic-metrics-key"
        let coldRecorder = HTTPMetricsRecorder()
        let data = try await VoiceHTTP.request(
            endpoint: endpoint, path: "cold-synthetic-path-secret",
            body: Data("synthetic-request-secret".utf8), timeout: 3,
            onMetrics: { coldRecorder.record($0) }
        )
        try require(String(data: data, encoding: .utf8)?.contains("synthetic-response-secret") == true,
                    "timed response body changed")
        let cold = try await collected(coldRecorder)
        let first = cold.transactions[0]
        try require(!first.isReusedConnection && first.tcpDuration != nil, "cold connection setup missing")
        try require(first.tlsDuration == nil, "HTTP reported TLS")
        try require((first.responseWaitDuration ?? 0) >= 0.07, "first-byte wait not measured")
        try require((first.downloadDuration ?? 0) >= 0.07, "download not measured")

        endpoint.apiKey = "synthetic-other-key"
        let warmRecorder = HTTPMetricsRecorder()
        _ = try await VoiceHTTP.request(endpoint: endpoint, path: "warm", body: nil, timeout: 3,
                                        onMetrics: { warmRecorder.record($0) })
        let warm = try await collected(warmRecorder)
        try require(warm.transactions[0].isReusedConnection, "timing delegate prevented connection reuse")
        try require(warm.transactions[0].dnsDuration == nil && warm.transactions[0].tcpDuration == nil &&
                    warm.transactions[0].tlsDuration == nil, "reused setup was reported as measured")

        endpoint.apiKey = ""
        _ = try await VoiceHTTP.request(endpoint: endpoint, path: "anonymous", body: nil, timeout: 3)
        endpoint.apiKey = "synthetic-metrics-key"
        let redirectRecorder = HTTPMetricsRecorder()
        for timed in [false, true] {
            let callback: (@Sendable (VoiceHTTP.Metrics) -> Void)? = timed ? { @Sendable in redirectRecorder.record($0) } : nil
            do {
                _ = try await VoiceHTTP.request(endpoint: endpoint, path: "redirect", body: nil, timeout: 3,
                                                onMetrics: callback)
                try require(false, "redirect accepted")
            } catch VoiceHTTP.Failure.requestRejected(let status, _, let code) {
                try require(status == 302 && code == nil, "redirect status or error sanitization changed")
            }
        }
        _ = try await collected(redirectRecorder)

        let invalidRecorder = HTTPMetricsRecorder()
        var invalid = endpoint
        invalid.apiKey = "bad\nheader"
        do {
            _ = try await VoiceHTTP.request(endpoint: invalid, path: "models", body: nil, timeout: 3,
                                            onMetrics: { invalidRecorder.record($0) })
            try require(false, "invalid credential accepted with metrics")
        } catch VoiceHTTP.Failure.credential {}
        try require(invalidRecorder.metrics.isEmpty, "preflight failure fabricated metrics")

        let cancelRecorder = HTTPMetricsRecorder()
        let cancelEndpoint = endpoint
        let pending = Task {
            try await VoiceHTTP.request(endpoint: cancelEndpoint, path: "cancel", body: nil, timeout: 5,
                                        onMetrics: { cancelRecorder.record($0) })
        }
        defer { pending.cancel() }
        var ready = false
        for _ in 0..<50 {
            let state = try await VoiceHTTP.request(endpoint: endpoint, path: "cancel-state", body: nil, timeout: 3)
            ready = (try JSONSerialization.jsonObject(with: state) as? [String: Bool])?["ready"] == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(ready, "cancelled request never reached server")
        let start = ContinuousClock.now
        pending.cancel()
        do {
            _ = try await pending.value
            try require(false, "cancelled HTTP request succeeded")
        } catch is CancellationError {
        } catch let error as URLError {
            try require(error.code == .cancelled, "HTTP cancellation changed error")
        }
        try require(start.duration(to: .now) < .seconds(2), "HTTP cancellation was not prompt")
        _ = try await collected(cancelRecorder)
        try require(coldRecorder.metrics.count == 1 && warmRecorder.metrics.count == 1 &&
                    redirectRecorder.metrics.count == 1, "metrics leaked across tasks")
        let deadlineStart = ContinuousClock.now
        do {
            _ = try await VoiceHTTP.request(endpoint: endpoint, path: "trickle", body: nil, timeout: 0.15)
            try require(false, "continuous slow bytes escaped the total deadline")
        } catch let error as URLError {
            try require(error.code == .timedOut && deadlineStart.duration(to: .now) < .milliseconds(500), "request deadline did not bound slow downloads")
        }
        print("PASS HTTP metrics: cold/reused, first byte/download, redirect rejection, cancellation, secret isolation")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "VoiceProviderCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor
    static func main() async throws {
        let fish = VoiceProviderPreset.speech.first { $0.id == "fish" }!
        let customSTT = VoiceProviderPreset.speech.first { $0.id == "openai-custom" }!
        try require(fish.endpoint.baseURL == "https://api.fish.audio/v1/asr", "Fish base URL changed")
        try require(fish.endpoint.model == "transcribe-1-pro" && fish.endpoint.resolvedProtocol.rawValue == "fish-asr", "Fish model/protocol changed")
        try require(VoiceProviderPreset.matching(fish.endpoint, speech: true)?.id == "fish", "Fish inferred as generic provider")
        try require(!VoiceModelDiscovery.supportsModelDiscovery(endpoint: fish.endpoint), "Fish native must not use OpenAI models API")
        let legacyFish = VoiceEndpoint(baseURL: "https://api.fish.audio/compat/v1", model: "fish-audio/transcribe-1", apiKey: "synthetic-fish-key", protocolType: "openai")
        try require(legacyFish.resolvedProtocol == .fishASR, "old Fish profile did not migrate to native ASR")
        let migrated = legacyFish.normalizedFishASR
        try require(migrated.model == "transcribe-1-pro" && migrated.apiKey == legacyFish.apiKey && migrated.baseURL == fish.endpoint.baseURL, "Fish migration changed key or retained legacy model/path")
        var speechSettings = VoiceSettings()
        speechSettings.asr = fish.endpoint
        speechSettings.asr.apiKey = "synthetic-fish-key"
        speechSettings.asr = speechSettings.asrProfiles.select(customSTT, current: speechSettings.asr, inferredID: "fish")
        try require(speechSettings.asr.apiKey.isEmpty, "Fish key leaked into custom STT")
        speechSettings.asr.baseURL = CommandLine.arguments[1] + "/v1/audio/transcriptions"
        speechSettings.asr.model = "synthetic-stt"
        speechSettings.asr.apiKey = "synthetic-stt-key"
        let savedCustom = speechSettings.asr
        speechSettings.asr = speechSettings.asrProfiles.select(fish, current: speechSettings.asr, inferredID: customSTT.id)
        try require(speechSettings.asr.apiKey == "synthetic-fish-key", "Fish key not restored")
        speechSettings.asr = speechSettings.asrProfiles.select(customSTT, current: speechSettings.asr, inferredID: fish.id)
        try require(speechSettings.asr == savedCustom, "STT URL/model/key not restored together")
        let clip = RecordedAudio(wav: Data(repeating: 0, count: 64), duration: 1)
        let customText = try await VoiceTranscriber().transcribe(clip, settings: speechSettings)
        try require(customText == "测试GitHub123", "custom STT transcript changed")
        speechSettings.asr = fish.endpoint
        speechSettings.asr.baseURL = CommandLine.arguments[1] + "/compat/v1"
        speechSettings.asr.apiKey = "synthetic-fish-key"
        let fishText = try await VoiceTranscriber().transcribe(clip, settings: speechSettings)
        try require(fishText == "测试GitHub123", "Fish compatible transcript changed")
        speechSettings.asr.apiKey = "synthetic-wrong-key"
        do {
            _ = try await VoiceTranscriber().transcribe(clip, settings: speechSettings)
            try require(false, "STT accepted a 401 response")
        } catch FishSpeechTranscription.Failure.http(401) {}
        speechSettings.asr.apiKey = "synthetic-quota-key"
        do {
            _ = try await VoiceTranscriber().transcribe(clip, settings: speechSettings)
            try require(false, "Fish accepted a 402 response")
        } catch FishSpeechTranscription.Failure.http(402) {
            let message = FishSpeechTranscription.Failure.http(402).localizedDescription
            try require(message.contains("API余额不足") && !message.contains("synthetic"), "Fish quota diagnostic is missing or leaked credentials")
        }
        speechSettings.asr.apiKey = "synthetic-fish-key"
        speechSettings.asr.model = "transcribe-1"
        let basicText = try await VoiceTranscriber().transcribe(clip, settings: speechSettings)
        try require(basicText == "测试GitHub123", "Fish native session did not return clean final text")
        print("PASS STT: Fish native Pro/basic, legacy migration, auto language, clean transcript, 401/402, isolated preset round-trip")
        let bai = VoiceProviderPreset.decision.first { $0.id == "bai" }!
        let laya = VoiceProviderPreset.decision.first { $0.id == "laya" }!
        var settings = VoiceSettings()
        settings.decision = bai.endpoint
        settings.decision.apiKey = "synthetic-bai"
        settings.decision = settings.decisionProfiles.select(laya, current: settings.decision, inferredID: "bai")
        try require(settings.decision.apiKey.isEmpty, "new preset inherited credential")
        settings.decision.baseURL = "https://example.invalid/v1"
        settings.decision.model = "custom-laya"
        settings.decision.apiKey = "synthetic-laya"
        let edited = settings.decision
        settings.decision = settings.decisionProfiles.select(bai, current: settings.decision, inferredID: nil)
        try require(settings.decision.apiKey == "synthetic-bai", "BAI key not restored")
        settings = try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(settings))
        settings.decision = settings.decisionProfiles.select(laya, current: settings.decision, inferredID: nil)
        try require(settings.decision == edited, "profile lost after persistence")
        settings.decision = settings.decisionProfiles.select(laya, current: settings.decision, inferredID: nil)
        try require(settings.decision == edited, "same preset lost edits")
        try require(settings.llmProfiles.entries.isEmpty && settings.asrProfiles.entries.isEmpty, "profile crossed role boundary")
        let legacySettings = try JSONDecoder().decode(VoiceSettings.self, from: Data("{}".utf8))
        try require(legacySettings.decisionProfiles.entries.isEmpty, "legacy profile migration failed")
        try require(bai.decisionProtocol == "jev-decisions" && laya.decisionProtocol == "jev-systemone", "decision protocol mismatch")
        let custom = VoiceProviderPreset.text.first { $0.id == "openai-custom" }!
        let ark = VoiceProviderPreset.text.first { $0.endpoint.usesArk }!
        var previous = VoiceEndpoint(baseURL: "https://api.deepseek.com", apiKey: "synthetic-old-key")
        var profiles = VoiceProviderProfiles()
        try require(profiles.select(ark, current: previous, inferredID: "deepseek").apiKey.isEmpty, "cross-provider switch leaked old key")
        profiles = VoiceProviderProfiles()
        try require(profiles.select(custom, current: previous, inferredID: "deepseek").apiKey.isEmpty, "custom provider inherited key")
        try require(VoiceModelDiscovery.supportsModelDiscovery(endpoint: ark.endpoint),
                    "Ark model-list button is disabled despite inference API support")
        var endpoint = custom.endpoint
        endpoint.baseURL = CommandLine.arguments[1] + "/v1/chat/completions"
        endpoint.apiKey = "  synthetic-key\n"
        try require(VoiceProviderPreset.matching(endpoint, speech: false)?.id == custom.id, "custom preset lost after editing URL")
        try await checkHTTPMetrics(endpoint: endpoint)
        let models = try await VoiceModelDiscovery.models(endpoint: endpoint)
        try require(models == ["test-model"], "custom model discovery failed")
        let data = try await VoiceHTTP.request(endpoint: endpoint, path: "chat/completions", body: Data("{}".utf8), timeout: 3)
        try require(String(data: data, encoding: .utf8) == "{}", "custom request failed")
        endpoint.apiKey = "bad\nheader"
        do {
            _ = try await VoiceModelDiscovery.models(endpoint: endpoint)
            try require(false, "embedded newline accepted")
        } catch VoiceHTTP.Failure.credential {}
        endpoint.apiKey = "synthetic-wrong-key"
        do {
            _ = try await VoiceHTTP.request(endpoint: endpoint, path: "auth-format", body: Data("{}".utf8), timeout: 3)
            try require(false, "malformed key accepted")
        } catch let failure as VoiceHTTP.Failure {
            try require(failure.localizedDescription.contains("HTTP 401") && failure.localizedDescription.contains("格式错误"),
                        "provider key-format diagnosis was discarded")
        }
        do {
            _ = try await VoiceModelDiscovery.models(endpoint: endpoint)
            try require(false, "401 accepted")
        } catch let failure as VoiceHTTP.Failure {
            try require(failure.localizedDescription.contains("鉴权失败") && failure.localizedDescription.contains("AuthenticationError"), "401 diagnosis lost")
        }

        let stream = VoiceProviderPreset.speech.first { $0.id == "volc-stream-2" }!
        let flash = VoiceProviderPreset.speech.first { $0.id == "volc-flash" }!
        previous = stream.endpoint
        previous.apiKey = "  synthetic-speech-key\n"
        let request = try VolcStreamingRecognition.connectionRequest(endpoint: previous)
        try require(request.url?.absoluteString == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async", "stream URL changed")
        try require(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration", "wrong 2.0 resource")
        try require(request.value(forHTTPHeaderField: "X-Api-Key") == "synthetic-speech-key", "speech key not trimmed")
        try require(request.value(forHTTPHeaderField: "X-Api-App-Key") == nil, "new auth mixed with legacy")
        let requestID = request.value(forHTTPHeaderField: "X-Api-Request-Id")
        try require(requestID.flatMap(UUID.init(uuidString:)) != nil && requestID == request.value(forHTTPHeaderField: "X-Api-Connect-Id"), "missing request tracking")
        try require(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1", "missing sequence")
        var flashEndpoint = flash.endpoint
        flashEndpoint.apiKey = previous.apiKey
        let audio = RecordedAudio(wav: Data([1, 2, 3]), duration: 1)
        let flashRequest = try VoiceTranscriber.volcFlashRequest(audio, endpoint: flashEndpoint, hotwords: ["GitHub"])
        try require(flashRequest.url?.absoluteString == "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash", "flash URL changed")
        try require(flashRequest.httpMethod == "POST" && flashRequest.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.auc_turbo", "flash method/resource wrong")
        try require(flashRequest.value(forHTTPHeaderField: "X-Api-Key") == "synthetic-speech-key", "flash credential wrong")
        let body = try JSONSerialization.jsonObject(with: flashRequest.httpBody!) as! [String: Any]
        try require((body["audio"] as? [String: String])?["data"] == audio.wav.base64EncodedString(), "flash audio damaged")
        let recognition = body["request"] as? [String: Any]
        try require(recognition?["model_name"] as? String == "bigmodel" && recognition?["corpus"] != nil, "flash model/hotwords missing")
        previous.speechAuthMode = "legacy"
        previous.appID = "test-app"
        let legacy = try VolcStreamingRecognition.connectionRequest(endpoint: previous)
        try require(legacy.value(forHTTPHeaderField: "X-Api-Key") == nil && legacy.value(forHTTPHeaderField: "X-Api-App-Key") == "test-app" && legacy.value(forHTTPHeaderField: "X-Api-Access-Key") == "synthetic-speech-key", "legacy auth damaged")
        let rejected = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)
        let failure = VolcStreamingRecognition.transportFailure(URLError(.badServerResponse), response: rejected)
        try require(failure.localizedDescription.contains("HTTP 401") && failure.localizedDescription.contains("火山方舟"), "handshake status lost")
        print("PASS custom provider, credential isolation, request normalization, Doubao streaming/flash/legacy authentication and errors")
    }
}

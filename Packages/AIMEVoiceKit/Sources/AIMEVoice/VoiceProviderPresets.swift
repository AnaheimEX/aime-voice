import Foundation

public enum VoiceAPIProtocol: String, Sendable, CaseIterable {
    case openAI = "openai", anthropic, volcStreaming = "volc-streaming", volcFlash = "volc-flash"
    case apple, codex, jev, layaPredict = "laya-predict"
    case bailianStreaming = "bailian-streaming", mimoASR = "mimo-asr", fishASR = "fish-asr"

    public var title: String {
        switch self {
        case .openAI: "OpenAI 兼容"
        case .fishASR: "Fish 原生语音识别"
        case .bailianStreaming: "阿里百炼流式语音"
        case .mimoASR: "小米 MiMo 语音识别"
        case .anthropic: "Anthropic Messages"
        case .volcStreaming: "豆包流式语音"
        case .volcFlash: "豆包极速语音"
        case .apple: "macOS 本机识别"
        case .codex: "Codex 订阅"
        case .jev: "JEV / System One"
        case .layaPredict: "Laya / predict"
        }
    }
}

extension VoiceEndpoint {
    public var resolvedProtocol: VoiceAPIProtocol {
        if usesFishSpeech, ["auto", "openai", "fish-realtime", "fish-asr"].contains(protocolType) { return .fishASR }
        if protocolType != "auto", let value = VoiceAPIProtocol(rawValue: protocolType) { return value }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .openAI }
        if url.scheme == "apple" { return .apple }
        if url.scheme == "codex" { return .codex }
        let path = url.path.lowercased()
        if url.scheme == "wss", path == "/api-ws/v1/inference" { return .bailianStreaming }
        if usesMiMo, model.lowercased().contains("asr") { return .mimoASR }
        if url.host?.lowercased() == "openspeech.bytedance.com" {
            return path.contains("/auc/") ? .volcFlash : .volcStreaming
        }
        if path.contains("/anthropic") || path.hasSuffix("/messages") || url.host == "api.anthropic.com" { return .anthropic }
        if path.hasSuffix("/systemone") || path.hasSuffix("/decisions") { return .jev }
        return .openAI
    }

    /// Fixed request policy, independent of old saved thinking settings.
    /// Field names follow Type4Me's provider-specific disabling strategy.
    public var nonThinkingParameters: [String: Any] {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        let name = model.lowercased()
        if host == "openrouter.ai" { return ["reasoning": ["effort": "none"]] }
        // OpenAI-compatible gateways need the same field as the selected GPT model.
        if name.hasPrefix("gpt-5") || name.hasPrefix("gpt-6") || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            return ["reasoning_effort": "none"]
        }
        if host == "api.openai.com" { return [:] }
        if host == "dashscope.aliyuncs.com" || host.hasPrefix("dashscope-") {
            return ["enable_thinking": false]
        }
        return ["thinking": ["type": "disabled"]]
    }

    public func decisionOperation(protocolName: String) -> String {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let path = (url?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A complete operation URL takes precedence over a protocol's base-URL default.
        if path.hasSuffix("/decisions") || path == "decisions" { return "decisions" }
        if path.hasSuffix("/systemone") || path == "systemone" { return "systemone" }
        if protocolName == "jev-decisions" { return "decisions" }
        if protocolName == "jev-systemone" { return "systemone" }
        return url?.host?.lowercased() == "api.b.ai" ? "decisions" : "systemone"
    }

    public var usesMiMo: Bool { URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() == "api.xiaomimimo.com" }
    public var usesArk: Bool { URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() == "ark.cn-beijing.volces.com" }
    public var usesDeepSeek: Bool { URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() == "api.deepseek.com" }
}

extension VoiceEndpoint {
    public var usesFishSpeech: Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host?.lowercased() == "api.fish.audio" else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "v1/asr" || path == "v1" || path == "compat/v1" || path.hasPrefix("compat/v1/")
    }

    var normalizedFishASR: VoiceEndpoint {
        guard usesFishSpeech, resolvedProtocol == .fishASR else { return self }
        var result = self
        result.baseURL = "https://api.fish.audio/v1/asr"
        result.protocolType = "fish-asr"
        if ["", "fish-audio/transcribe-1", "whisper-1"].contains(model.trimmingCharacters(in: .whitespacesAndNewlines)) {
            result.model = "transcribe-1-pro"
        }
        return result
    }

    public var usesFishCompatible: Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.host?.lowercased() == "api.fish.audio" && (url.path == "/compat/v1" || url.path.hasPrefix("/compat/v1/"))
    }
}

public struct VoiceProviderPreset: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let endpoint: VoiceEndpoint
    public let documentationURL: String

    public static let speech: [Self] = [
        .init(id: "fish", title: "Fish Audio · 原生识别", endpoint: .init(baseURL: "https://api.fish.audio/v1/asr", model: "transcribe-1-pro", protocolType: "fish-asr"), documentationURL: "https://docs.fish.audio/features/speech-to-text"),
        .init(id: "openai-custom", title: "OpenAI 兼容 · 自定义 STT", endpoint: .init(baseURL: "", protocolType: "openai"), documentationURL: ""),
        .init(id: "bailian", title: "阿里百炼 · 实时语音识别", endpoint: .init(baseURL: "wss://dashscope.aliyuncs.com/api-ws/v1/inference", protocolType: "bailian-streaming"), documentationURL: "https://help.aliyun.com/zh/model-studio/qwen-audio-asr-streaming-websocket-api"),
        .init(id: "mimo-asr", title: "小米 MiMo · 语音识别", endpoint: .init(baseURL: "https://api.xiaomimimo.com/v1", protocolType: "mimo-asr"), documentationURL: "https://mimo.mi.com/docs/en-US/api/audio/Speech-Recognition"),
        .init(id: "apple", title: "Apple · macOS 本机识别", endpoint: .init(baseURL: "apple://speech"), documentationURL: "https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition"),
        .init(id: "volc-stream-2", title: "豆包 · 流式识别 2.0", endpoint: .init(baseURL: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async", resourceID: "volc.seedasr.sauc.duration"), documentationURL: "https://www.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI"),
        .init(id: "volc-stream-1", title: "豆包 · 流式识别 1.0", endpoint: .init(baseURL: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async", resourceID: "volc.bigasr.sauc.duration"), documentationURL: "https://www.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI"),
        .init(id: "volc-flash", title: "豆包 · 极速录音转写", endpoint: .init(baseURL: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash", resourceID: "volc.bigasr.auc_turbo"), documentationURL: "https://docs.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfileLiterecognitionAPI?lang=zh")
    ]

    public static let text: [Self] = [
        .init(id: "openai-custom", title: "OpenAI 兼容 · 自定义", endpoint: .init(baseURL: "", protocolType: "openai"), documentationURL: ""),
        .init(id: "ark", title: "豆包 · 火山方舟", endpoint: .init(baseURL: "https://ark.cn-beijing.volces.com/api/v3"), documentationURL: "https://www.volcengine.com/docs/ark/model-list"),
        .init(id: "codex", title: "Codex · ChatGPT 订阅", endpoint: .init(baseURL: "codex://subscription"), documentationURL: "https://developers.openai.com/codex/app-server"),
        .init(id: "deepseek", title: "DeepSeek", endpoint: .init(baseURL: "https://api.deepseek.com"), documentationURL: "https://api-docs.deepseek.com/quick_start/pricing"),
        .init(id: "mimo", title: "MiMo · 2.6 系列", endpoint: .init(baseURL: "https://api.xiaomimimo.com/v1"), documentationURL: "https://mimo.mi.com/docs/quick-start/summary/model")
    ]

    public static func matching(_ endpoint: VoiceEndpoint, speech: Bool) -> Self? {
        if speech {
            if endpoint.usesFishSpeech { return Self.speech.first { $0.id == "fish" } }
            if endpoint.resolvedProtocol == .openAI { return Self.speech.first { $0.id == "openai-custom" } }
        }
        if !speech, endpoint.protocolType == VoiceAPIProtocol.openAI.rawValue {
            return Self.text.first { $0.id == "openai-custom" }
        }
        return (speech ? Self.speech : Self.text).first {
            $0.endpoint.baseURL == endpoint.baseURL && (endpoint.resourceID.isEmpty || $0.endpoint.resourceID == endpoint.resourceID)
        }
    }

    public static let decision: [Self] = [
        .init(id: "laya-predict", title: "Laya · 本地决策", endpoint: .init(baseURL: "http://127.0.0.1:8000", model: "laya", protocolType: "laya-predict"), documentationURL: ""),
        .init(id: "bai", title: "B.AI JEV", endpoint: .init(baseURL: "https://api.b.ai/v1", model: "jev-latest", protocolType: "jev"), documentationURL: ""),
        .init(id: "typesafe", title: "TypeSafe JEV", endpoint: .init(baseURL: "https://api.typesafe.ai/v1", model: "jev-latest", protocolType: "jev"), documentationURL: ""),
        .init(id: "laya", title: "Laya · System One", endpoint: .init(baseURL: "", protocolType: "jev"), documentationURL: ""),
        .init(id: "openai-custom", title: "OpenAI 兼容", endpoint: .init(baseURL: "https://api.openai.com/v1", protocolType: "openai"), documentationURL: "")
    ]

    public var decisionProtocol: String {
        switch id {
        case "bai": "jev-decisions"
        case "openai-custom": "openai"
        case "laya-predict": "laya-predict"
        default: "jev-systemone"
        }
    }

    public static func matchingDecision(_ endpoint: VoiceEndpoint, protocolName: String) -> Self? {
        let id: String
        if protocolName == "laya-predict" { id = "laya-predict" }
        else if protocolName == "openai" { id = "openai-custom" }
        else {
            switch URL(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() {
            case "api.b.ai": id = "bai"
            case "api.typesafe.ai": id = "typesafe"
            default: id = "laya"
            }
        }
        return decision.first { $0.id == id }
    }
}

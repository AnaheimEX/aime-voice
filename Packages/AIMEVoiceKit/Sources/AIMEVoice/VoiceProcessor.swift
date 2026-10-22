public import Foundation
import OSLog

let vocabularyLatencyLogger = Logger(subsystem: "app.zool.aime.voice", category: "latency")

public struct VoiceProcessingResult: Codable, Sendable {
    public let text: String
    public let route: String
    public let decisionInvoked: Bool
    public let decisionAdopted: Bool
    public let elapsedMilliseconds: Int
    public var finalCorrections: Int = 0
}

public struct VoiceDecisionTestResult: Sendable {
    public let route: String
    public let probability: Double
    public let confidence: Double
    public let elapsedMilliseconds: Int

    public var classificationAccepted: Bool? = nil
    public var isConfident: Bool { classificationAccepted ?? (probability >= 0.95 && confidence >= 0.90) }
    public let budgetMilliseconds: Int
    public var meetsRuntimeBudget: Bool { elapsedMilliseconds <= budgetMilliseconds }
}

/// One voice utterance in, one final output out. Decisions can finish early; the original model always remains available.
public struct VoiceProcessor: Sendable {
    static let latencyPolicy = VoiceLatencyPolicy()
    public init() {}

    /// Rewrite an explicitly selected span. Never routes through dictation or falls back to unedited text.
    public func rewrite(_ selectedText: String, instruction: String, settings: VoiceSettings, singleLine: Bool = false) async throws -> VoiceProcessingResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !instruction.isEmpty else { throw VoiceHTTP.Failure.empty }
        guard selectedText.count <= 2000, instruction.count <= 500 else {
            throw ProcessingFailure.rewriteTooLong
        }
        let request = VoiceRewriteEngine.makeRequest(selectedText, instruction: instruction, singleLine: singleLine)
        if let output = try VoiceRewriteEngine.localCandidate(for: request) {
            try Task.checkCancellation()
            let elapsed = started.duration(to: .now)
            return VoiceProcessingResult(text: output, route: "rewrite_local", decisionInvoked: false,
                                         decisionAdopted: false,
                                         elapsedMilliseconds: elapsed.wholeMilliseconds)
        }
        guard settings.llm.isConfigured else { throw ProcessingFailure.missingModel }
        let response = try await Self.complete(endpoint: settings.llm, instructions: VoiceRewriteEngine.systemPrompt,
            text: VoiceRewriteEngine.userPrompt(for: request), preserveWhitespace: true)
        let output = try VoiceRewriteEngine.validate(response, for: request)
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now)
        return VoiceProcessingResult(text: output, route: "rewrite", decisionInvoked: false,
                                     decisionAdopted: false,
                                     elapsedMilliseconds: elapsed.wholeMilliseconds)
    }

    /// Validate the selected model with a small fixed request, independent of task prompts.
    public func testPolish(text: String, settings: VoiceSettings) async throws -> VoiceProcessingResult {
        guard settings.llm.isConfigured else { throw ProcessingFailure.missingModel }
        let started = ContinuousClock.now
        let output = try await Self.complete(endpoint: settings.llm, instructions: "仅回复：连接正常", text: text)
        let milliseconds = started.duration(to: .now).wholeMilliseconds
        return VoiceProcessingResult(text: output, route: "connection_test", decisionInvoked: false,
                                     decisionAdopted: false, elapsedMilliseconds: milliseconds)
    }

    /// Connection tests allow cold starts; production classification keeps its configured deadline.
    public func testDecision(text: String, settings: VoiceSettings) async throws -> VoiceDecisionTestResult {
        try Task.checkCancellation()
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw VoiceHTTP.Failure.empty }
        guard settings.decision.isConfigured else { throw ProcessingFailure.missingDecisionModel }
        let started = ContinuousClock.now
        let timeout = settings.decisionProtocol == "laya-predict"
            ? Double(settings.effectiveDecisionBudgetMilliseconds) / 1000 : 15
        let decision = try await Self.classify(text: input, settings: settings, timeout: timeout)
        try Task.checkCancellation()
        let milliseconds = started.duration(to: .now).wholeMilliseconds
        var result = VoiceDecisionTestResult(route: decision.route, probability: decision.probability,
            confidence: decision.confidence, elapsedMilliseconds: milliseconds,
            budgetMilliseconds: settings.effectiveDecisionBudgetMilliseconds)
        if settings.decisionProtocol == "laya-predict" { result.classificationAccepted = decision.route != "abstain" }
        return result
    }

    public func process(_ transcript: String, settings: VoiceSettings) async throws -> VoiceProcessingResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceHTTP.Failure.empty }
        // One replacement pass before any model. A later pass would let rules cascade twice.
        let correctionStarted = ContinuousClock.now
        if settings.mode == "polish", let term = settings.vocabulary.directTerm(matching: trimmed) {
            let applied = settings.vocabulary.apply(to: term)
            Self.logCorrection(applied.replacementCount, started: correctionStarted)
            let elapsed = started.duration(to: .now)
            return VoiceProcessingResult(text: applied.text.isEmpty ? term : applied.text, route: "dictionary_local",
                decisionInvoked: false, decisionAdopted: false,
                elapsedMilliseconds: elapsed.wholeMilliseconds,
                finalCorrections: applied.replacementCount)
        }
        let applied = settings.vocabulary.apply(to: trimmed)
        Self.logCorrection(applied.replacementCount, started: correctionStarted)
        let modelInput = applied.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await processTranscript(modelInput.isEmpty ? trimmed : modelInput, settings: settings, started: started)
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now)
        return VoiceProcessingResult(text: result.text, route: result.route,
            decisionInvoked: result.decisionInvoked, decisionAdopted: result.decisionAdopted,
            elapsedMilliseconds: elapsed.wholeMilliseconds,
            finalCorrections: applied.replacementCount)
    }

    static func logCorrection(_ count: Int, started: ContinuousClock.Instant) {
        let milliseconds = started.duration(to: .now).wholeMilliseconds
        vocabularyLatencyLogger.notice("stage=prePolishCorrection replacements=\(count) correctionMs=\(milliseconds)")
    }

    enum ProcessingFailure: LocalizedError {
        case missingModel, missingDecisionModel, missingPrompt, unsupportedContext, invalidDecision, rewriteTooLong, thinkingNotDisabled
        var errorDescription: String? {
            switch self {
            case .thinkingNotDisabled: "服务未关闭思考模式，结果未上屏；请换用支持非思考模式的模型"
            case .missingModel: "请先配置润色模型的接口地址和模型 ID"
            case .rewriteTooLong: "改写选区最多2000字，改写指令最多500字，请缩小选区或精简指令"
            case .missingDecisionModel: "请先配置决策模型的接口地址并拉取选择模型"
            case .missingPrompt: "自定义模式需要填写提示词"
            case .unsupportedContext: "此语音模式仅支持 {text}，不支持 {selected} 或 {clipboard} 上下文"
            case .invalidDecision: "决策接口未返回有效的四路决策结果或概率，无法验证 JEV 决策契约"
            }
        }
    }
}

extension Duration {
    /// Truncated, as every latency log line has always reported it.
    var wholeMilliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}

public import Foundation

/// AIME's text-only adapter for Type4Me ReviseCore, commit e24dfda (MIT).
/// The caller owns input limits, a single model request when needed, and focus-safe commit.
/// This adapter performs no external actions and requires no confirmation step.
public enum VoiceRewriteEngine {
    public static let systemPrompt = RevisePromptBuilder.systemPrompt

    /// Preserve the original text exactly. The caller enforces AIME's 2,000/500-character limits.
    public static func makeRequest(
        _ original: String,
        instruction: String,
        singleLine: Bool = false
    ) -> ReviseRequest {
        ReviseRequest(
            targetText: original,
            instruction: instruction,
            controlKind: singleLine ? .singleLine : .multiLine,
            sourceLanguage: ReviseLanguageProfile.detect(in: original),
            sourceModeKind: .voicePolish
        )
    }

    public static func userPrompt(for request: ReviseRequest) -> String {
        RevisePromptBuilder.buildUserPrompt(request: request)
    }

    /// How a rewrite was resolved without a model. Kept separate from the text so
    /// callers can log which path ran.
    public enum Resolution: Equatable, Sendable {
        /// An explicit replacement ("把 A 改成 B") applied locally.
        case explicit(String)
        /// The instruction was itself the wanted text, so the model is skipped.
        case restatement(String)
    }

    /// Deterministic paths in priority order: an explicit replacement first, then a
    /// restatement. Nil means the model is required. An explicit rejection throws
    /// before the restatement pass, so a rejected edit never becomes a restatement.
    public static func localResolution(for request: ReviseRequest) throws -> Resolution? {
        if let explicit = try explicitCandidate(for: request) { return .explicit(explicit) }
        if let restated = VoiceRewriteRestatement.candidate(for: request) { return .restatement(restated) }
        return nil
    }

    /// Return a validated deterministic replacement, or nil when a model is needed.
    /// Explicit replacements come first; a restatement (the instruction is itself the wanted text)
    /// resolves locally too. A rejected local candidate must propagate its error rather than
    /// trigger a model retry, so the restatement pass only runs when the explicit path finds nothing.
    public static func localCandidate(for request: ReviseRequest) throws -> String? {
        if let explicit = try explicitCandidate(for: request) { return explicit }
        return VoiceRewriteRestatement.candidate(for: request)
    }

    private static func explicitCandidate(for request: ReviseRequest) throws -> String? {
        let analysis = ReviseInstructionAnalyzer.analyze(request.instruction, targetText: request.targetText)
        let authorizationDecision = ReviseAuthorizationResolver.resolve(
            target: request.targetText,
            instruction: request.instruction,
            analysis: analysis
        )
        guard let authorization = analysis.replacementAuthorization,
              case .authorized(let ranges, _) = authorizationDecision,
              ranges.count == 1, let range = ranges.first,
              let candidate = ReviseOutputValidator.candidateByApplyingLocalReplacement(
                target: request.targetText,
                ranges: ranges,
                authorization: authorization
              ) else { return nil }

        let response = ReviseModelResponse(
            intent: .replace,
            scope: ReviseScopeDescriptor(
                kind: .literal,
                selector: String(request.targetText[range]),
                ordinal: analysis.ordinalReferences.first
            ),
            ambiguous: false,
            externalActionRequested: analysis.hasExternalActionTail,
            result: candidate
        )
        return try acceptedCandidate(ReviseOutputValidator.validate(request: request, response: response))
    }

    /// Validate the one model response as upstream JSON, without trimming or repairing its candidate.
    public static func validate(_ rawModelResponse: String, for request: ReviseRequest) throws -> String {
        try acceptedCandidate(ReviseOutputValidator.validate(request: request, rawModelResponse: rawModelResponse))
    }

    private static func acceptedCandidate(_ result: ReviseProcessingResult) throws -> String {
        switch result.decision {
        case .reject(let rejection):
            throw Failure.rejected(rejection)
        case .accept:
            guard let candidate = result.candidateText else { throw Failure.rejected(.noCandidate) }
            guard candidate != result.request.targetText else { throw Failure.noChanges }
            // Explicit deletion may produce an empty string. Commit the exact validated value.
            return candidate
        }
    }

    public enum Failure: LocalizedError, Sendable {
        case noChanges
        case rejected(ReviseRejection)

        public var errorDescription: String? {
            switch self {
            case .noChanges:
                return "改写没有产生修改，原文未改动"
            case .rejected(let rejection):
                switch rejection {
                case .emptyOutput, .noCandidate:
                    return "没有可用的改写结果"
                case .disallowedEmptyOutput:
                    return "未明确要求删除全部内容，不能提交空白改写结果"
                case .malformedJSON, .schemaVersionMismatch, .codeFence:
                    return "改写结果格式无效，请重试"
                case .modelAmbiguous, .implicitReplacementAmbiguous:
                    return "改写指令不明确，请说明要修改的内容"
                case .unsupportedIntent, .intentMismatch:
                    return "未识别到支持的文本改写指令"
                case .scopeMissing, .scopeNotFound:
                    return "未找到要修改的内容，请明确指定原文"
                case .scopeMultipleMatchesWithoutOrdinal:
                    return "找到多处匹配内容，请说明要修改哪一处"
                case .scopeOrdinalOutOfBounds:
                    return "指定的修改位置超出了原文范围"
                case .changeOutsideAuthorizedScope:
                    return "改写超出了指定范围，原文未改动"
                case .protectedTokenRemovedWithoutAuthorization, .protectedTokenAddedWithoutAuthorization,
                     .protectedFactConflict, .strongRelationChanged:
                    return "改写改变了未授权修改的事实或标识，原文未改动"
                case .languageChangedWithoutAuthorization:
                    return "未要求翻译，改写不能更换原文语言"
                case .singleLineViolation:
                    return "当前输入框只支持单行，改写结果不能包含换行"
                case .answerOrExplanation:
                    return "改写结果包含回答或解释，请重试"
                case .claimedExecution, .toolCall:
                    return "改写只支持修改文本，不能执行外部操作"
                case .sensitiveContentLeak:
                    return "改写结果新增了敏感内容，原文未改动"
                case .extremeExpansion:
                    return "改写结果扩写过多，原文未改动"
                case .diffBudgetExceeded:
                    return "改写差异过大或校验超时，请缩短原文后重试"
                case .targetTooLong, .instructionTooLong:
                    return "改写原文或指令过长，请缩短后重试"
                case .responseTooLarge:
                    return "改写响应过大，请重试"
                }
            }
        }
    }
}

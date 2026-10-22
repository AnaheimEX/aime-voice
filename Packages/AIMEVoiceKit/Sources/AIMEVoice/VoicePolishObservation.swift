public import Foundation
import OSLog
import Synchronization

/// Post-commit observation only. Never supplies text to the processing or commit path.
public enum VoicePolishObservation {
    public enum Source: Int, Codable, Sendable {
        case other, polish, hedge, local, decision, fallback

        init(route: String) {
            switch route {
            case "original", "laya_light", "laya_heavy": self = .polish
            case "slow_polish_hedge": self = .hedge
            case "short_local", "dictionary_local": self = .local
            case "no_edit", "local_edit", "laya_none": self = .decision
            case "empty_polish_fallback": self = .fallback
            default: self = route.hasPrefix("original (decision: ") ? .polish : .other
            }
        }

        var hasPolishReference: Bool { self == .polish || self == .hedge }
    }

    public struct Processing: Codable, Sendable {
        public let source: Source
        public let milliseconds: Int
        public let finalCorrections: Int

        init(_ result: VoiceProcessingResult) {
            source = Source(route: result.route)
            milliseconds = result.elapsedMilliseconds
            finalCorrections = result.finalCorrections
        }
    }

    enum Policy: Int, Sendable { case unsupported, standard, chat, joinedChat }
    enum Rule: Int, Sendable {
        case eligible, unsupportedPolicy, tooLarge, empty, tooLong, filler, correction, list, number, negation, structure, repetition
    }

    struct Context: Sendable {
        let policy: Policy
        let vocabulary: VoiceVocabulary

        init(_ settings: VoiceSettings) {
            if settings.mode != "polish" { policy = .unsupported }
            else if settings.effectivePolishStyle == .standard { policy = .standard }
            else if settings.effectivePolishStyle == .chat { policy = .chat }
            else if settings.polishPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == VoiceProcessor.joinedChatPolishInstructions {
                policy = .joinedChat
            } else { policy = .unsupported }
            vocabulary = settings.vocabulary
        }
    }

    struct Measurement: Sendable {
        let rule: Rule
        let length: Int
        let compared: Bool
        let distance: Int
        let normalizedLength: Int
        let exactMatch: Bool
        let sensitiveChanged: Bool
        let candidateCorrections: Int
    }

    private static let logger = Logger(subsystem: "app.zool.aime.voice", category: "latency")
    private static let busy = Mutex(false)
    private static let maxBytes = 512
    private static let maxCharacters = 128
    private static let fillers = ["嗯", "呃", "啊", "哦", "那个", "就是", "你知道", "怎么说"]
    private static let corrections = ["不对", "我是说", "改成", "算了", "应该是", "重说"]
    private static let lists = ["第一", "第二", "首先", "其次", "然后", "最后", "以下", "如下", "以及", "还有"]
    private static let numberCharacters = Set("零〇一二两三四五六七八九十百千万亿兆半")
    private static let negationCharacters = Set("不没无别否勿未非")
    private static let trailing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。，！？；：、…,.!?;:"))

    /// Called only after successful insertion. One background job, no queued transcripts.
    public static func recordAfterCommit(transcript: String, committed: String,
                                         settings: VoiceSettings, processing: Processing) {
        guard settings.mode == "polish" else { return }
        let admitted = busy.withLock { active in
            guard !active else { return false }
            active = true
            return true
        }
        guard admitted else { return }
        Task.detached(priority: .background) {
            defer { busy.withLock { $0 = false } }
            let started = ContinuousClock.now
            let context = Context(settings)
            let value = measure(transcript: transcript, committed: committed, context: context, source: processing.source)
            let duration = started.duration(to: .now)
            let microseconds = Int(duration.components.seconds * 1_000_000 + duration.components.attoseconds / 1_000_000_000_000)
            // Fixed numeric fields only: no text, matched words, hashes, prompts, URLs or credentials.
            logger.notice("stage=polishShadow version=1 policy=\(context.policy.rawValue) source=\(processing.source.rawValue) rule=\(value.rule.rawValue) length=\(value.length) eligible=\(value.rule == .eligible) compared=\(value.compared) distance=\(value.distance) normalizedLength=\(value.normalizedLength) exactMatch=\(value.exactMatch) sensitiveChanged=\(value.sensitiveChanged) candidateCorrections=\(value.candidateCorrections) finalCorrections=\(processing.finalCorrections) processingMs=\(processing.milliseconds) observationUs=\(microseconds)")
        }
    }

    static func measure(transcript: String, committed: String, context: Context, source: Source) -> Measurement {
        func skipped(_ rule: Rule, length: Int = -1) -> Measurement {
            Measurement(rule: rule, length: length, compared: false, distance: -1, normalizedLength: -1,
                        exactMatch: false, sensitiveChanged: false, candidateCorrections: 0)
        }
        guard context.policy != .unsupported else { return skipped(.unsupportedPolicy) }
        guard bounded(transcript), bounded(committed) else { return skipped(.tooLarge) }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = text.count
        guard !text.isEmpty else { return skipped(.empty, length: length) }
        guard length <= 24 else { return skipped(.tooLong, length: length) }
        for (words, rule) in [(fillers, Rule.filler), (corrections, .correction), (lists, .list)] {
            if words.contains(where: text.contains) { return skipped(rule, length: length) }
        }
        guard !text.contains(where: { $0.isNumber || numberCharacters.contains($0) }) else { return skipped(.number, length: length) }
        guard !text.contains(where: negationCharacters.contains) else { return skipped(.negation, length: length) }
        let body = text.trimmingCharacters(in: trailing)
        guard !text.contains(where: \.isNewline), !body.isEmpty,
              body.range(of: #"^[\p{Han}A-Za-z \t]+$"#, options: .regularExpression) != nil else {
            return skipped(.structure, length: length)
        }
        let compact = String(body.filter { !$0.isWhitespace }).lowercased()
        guard compact.range(of: #"(.{1,8})\1"#, options: .regularExpression) == nil else { return skipped(.repetition, length: length) }
        let candidate: String
        if context.policy == .joinedChat {
            guard let joined = VoiceProcessor.joinedChatCandidate(text) else { return skipped(.structure, length: length) }
            candidate = joined
        } else if context.policy == .standard {
            candidate = VoicePolishFormatting.withoutTerminalPunctuation(text)
        } else {
            candidate = VoicePolishFormatting.spaceSeparated(text, joiningChineseWords: true)
        }
        guard source.hasPolishReference else { return skipped(.eligible, length: length) }
        // Compare like-for-like final outputs: apply the same dictionary exactly once.
        guard let corrected = context.vocabulary.observationResult(for: candidate, maximumUTF8Bytes: maxBytes),
              bounded(corrected.text) else { return skipped(.tooLarge, length: length) }
        let lhs = normalized(corrected.text), rhs = normalized(committed)
        return Measurement(rule: .eligible, length: length, compared: true,
                           distance: editDistance(lhs, rhs), normalizedLength: max(lhs.count, rhs.count),
                           exactMatch: corrected.text == committed,
                           sensitiveChanged: sensitive(corrected.text) != sensitive(committed),
                           candidateCorrections: corrected.replacementCount)
    }

    private static func bounded(_ text: String) -> Bool {
        text.utf8.prefix(maxBytes + 1).count <= maxBytes && text.prefix(maxCharacters + 1).count <= maxCharacters
    }

    private static func normalized(_ text: String) -> [Character] {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }.map { $0 }
    }

    private static func sensitive(_ text: String) -> String {
        String(text.filter { $0.isNumber || numberCharacters.contains($0) || negationCharacters.contains($0) })
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var current = [i + 1]
            for (j, b) in rhs.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (a == b ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

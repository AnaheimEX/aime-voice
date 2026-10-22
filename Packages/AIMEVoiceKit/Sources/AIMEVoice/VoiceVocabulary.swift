// Inspired by Type4Me HotwordStorage, SnippetStorage and VolcProtocol (MIT).
// Upstream: https://github.com/joewongjc/type4me ; see licenses/type4me.LICENSE.txt.
public import Foundation

/// Voice-only recognition hints and final-output replacements, owned by VoiceSettings.
/// Never reads or writes keyboard dictionaries, phrase tables, or Rime learned frequencies.
public struct VoiceVocabulary: Codable, Sendable, Equatable {
    public var hotwords: [String] = []
    public var replacements: [VoiceReplacement] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case hotwords, replacements }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hotwords = try values.decodeIfPresent([String].self, forKey: .hotwords) ?? []
        replacements = try values.decodeIfPresent([VoiceReplacement].self, forKey: .replacements) ?? []
    }

    public var normalizedHotwords: [String] {
        Self.normalize(hotwords)
    }

    public func validate() throws {
        guard normalizedHotwords.count <= 500 else { throw VoiceVocabularyError.invalid("热词最多 500 条") }
        guard normalizedHotwords.allSatisfy({ $0.count <= 80 }) else {
            throw VoiceVocabularyError.invalid("每条热词最多 80 个字符")
        }
        guard replacements.count <= 200 else { throw VoiceVocabularyError.invalid("纠错规则最多 200 条") }
        guard replacements.allSatisfy({ $0.sources.count <= VoiceReplacement.maximumSources }) else {
            throw VoiceVocabularyError.invalid("每条纠错规则最多 5 个触发词")
        }
        guard Set(replacements.map(\.id)).count == replacements.count else {
            throw VoiceVocabularyError.invalid("纠错规则的 ID 重复，请删除重复规则后重试")
        }
        var seen = Set<String>()
        for rule in replacements where rule.isEnabled {
            guard !rule.sources.isEmpty, rule.sources.count <= VoiceReplacement.maximumSources,
                  rule.sources.allSatisfy({ !Self.triggerKey($0).isEmpty }),
                  !rule.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceVocabularyError.invalid("已启用的规则需填写 1–5 个触发词和替换内容")
            }
            guard rule.sources.allSatisfy({ $0.count <= 80 }), rule.target.count <= 500 else {
                throw VoiceVocabularyError.invalid("触发词最多 80 个字符，替换内容最多 500 个字符")
            }
            for source in rule.sources {
                guard seen.insert(Self.triggerKey(source)).inserted else {
                    throw VoiceVocabularyError.invalid("触发词重复（忽略大小写和空白）")
                }
            }
        }
    }

    public func selectedHotwords(for endpoint: VoiceEndpoint) -> [String] {
        guard (try? validate()) != nil else { return [] }
        switch endpoint.resolvedProtocol {
        case .volcStreaming: return Self.streamingHotwords(hotwords)
        case .volcFlash, .apple: return Array(normalizedHotwords.prefix(500))
        default: return []
        }
    }

    /// Type4Me's conservative direct-hotword estimate: CJK = 1, Latin runs = ceil(n/3).
    /// Keep user order; skip terms which do not fit the streaming 100-token budget.
    static func streamingHotwords(_ words: [String]) -> [String] {
        var used = 0
        return normalize(words).prefix(500).filter { word in
            guard word.count <= 80 else { return false }
            let cost = estimatedTokens(word)
            guard used + cost <= 100 else { return false }
            used += cost
            return true
        }
    }

    static func corpusContext(_ words: [String]) throws -> String? {
        guard !words.isEmpty else { return nil }
        let data = try JSONSerialization.data(withJSONObject: ["hotwords": words.map { ["word": $0] }])
        return String(decoding: data, as: UTF8.self)
    }

    /// Whole utterance that is exactly one enabled replacement trigger, at any length, or a
    /// hotword of 1–4 non-whitespace characters. A longer hotword, or a term inside a sentence,
    /// stays on the polish path. The caller applies replacements once, so a trigger match
    /// returns the original term.
    func directTerm(matching transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline), (try? validate()) != nil else { return nil }
        let trailing = CharacterSet(charactersIn: "。！？.!?…")
        var core = trimmed
        while let scalar = core.unicodeScalars.last, trailing.contains(scalar) {
            core.unicodeScalars.removeLast()
        }
        core = core.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, !core.contains(where: \.isNewline) else { return nil }
        let key = Self.triggerKey(core)
        guard !key.isEmpty else { return nil }
        if replacements.contains(where: { rule in
            rule.isEnabled && rule.sources.contains { Self.triggerKey($0) == key }
        }) {
            return core
        }
        let compactCount = core.filter { !$0.isWhitespace }.count
        guard (1...4).contains(compactCount) else { return nil }
        return normalizedHotwords.first { Self.triggerKey($0) == key }
    }

    public func apply(to text: String) -> VoiceVocabularyResult {
        guard !text.isEmpty, (try? validate()) != nil, let compiled = Self.cache.rules(for: replacements) else {
            return VoiceVocabularyResult(text: text, replacementCount: 0)
        }
        // Match Type4Me SnippetStorage: user order, case/space-insensitive,
        // and each later rule sees the text produced by earlier rules.
        var output = text
        var count = 0
        for rule in compiled {
            let range = NSRange(output.startIndex..., in: output)
            let matches = rule.regex.numberOfMatches(in: output, range: range)
            guard matches > 0 else { continue }
            output = rule.regex.stringByReplacingMatches(in: output, range: range, withTemplate: rule.template)
            count += matches
        }
        return VoiceVocabularyResult(text: output, replacementCount: count)
    }

    /// Shadow comparisons must not expand cascading replacements beyond their work budget.
    /// Production replacement semantics remain unrestricted by this observation-only limit.
    func observationResult(for text: String, maximumUTF8Bytes: Int) -> VoiceVocabularyResult? {
        guard text.utf8.count <= maximumUTF8Bytes else { return nil }
        guard !text.isEmpty, (try? validate()) != nil, let compiled = Self.cache.rules(for: replacements) else {
            return VoiceVocabularyResult(text: text, replacementCount: 0)
        }
        var output = text
        var count = 0
        for rule in compiled {
            let range = NSRange(output.startIndex..., in: output)
            let matches = rule.regex.numberOfMatches(in: output, range: range)
            guard matches > 0 else { continue }
            // Escaped literal template length is a conservative upper bound; no allocation
            // proportional to an expanded result happens until it fits the observation budget.
            guard output.utf8.count + matches * rule.template.utf8.count <= maximumUTF8Bytes else { return nil }
            output = rule.regex.stringByReplacingMatches(in: output, range: range, withTemplate: rule.template)
            count += matches
        }
        return VoiceVocabularyResult(text: output, replacementCount: count)
    }

    private static let cache = VoiceReplacementCache()

    private static func normalize(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    fileprivate static func triggerKey(_ value: String) -> String {
        value.filter { !$0.isWhitespace }.lowercased()
    }

    private static func estimatedTokens(_ word: String) -> Int {
        var tokens = 0
        var latinRun = 0
        for scalar in word.unicodeScalars {
            if scalar.properties.isIdeographic {
                tokens += (latinRun + 2) / 3 + 1
                latinRun = 0
            } else if CharacterSet.alphanumerics.contains(scalar) {
                latinRun += 1
            } else {
                tokens += (latinRun + 2) / 3
                latinRun = 0
            }
        }
        return max(tokens + (latinRun + 2) / 3, 1)
    }
}

public struct VoiceReplacement: Identifiable, Codable, Sendable, Equatable {
    public static let maximumSources = 5
    public var id: UUID
    public var sources: [String]
    /// Keep the original single-trigger API for existing callers and saved dictionaries.
    public var source: String {
        get { sources.first ?? "" }
        set {
            if sources.isEmpty { sources = [newValue] }
            else { sources[0] = newValue }
        }
    }
    public var target: String
    public var isEnabled: Bool

    public init(source: String = "", target: String = "", isEnabled: Bool = true) {
        self.init(sources: source.isEmpty ? [] : [source], target: target, isEnabled: isEnabled)
    }

    public init(sources: [String], target: String = "", isEnabled: Bool = true) {
        id = UUID()
        self.sources = sources
        self.target = target
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, source, sources, target, isEnabled }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? id
        if let savedSources = try values.decodeIfPresent([String].self, forKey: .sources) {
            sources = savedSources
        } else if let savedSource = try values.decodeIfPresent(String.self, forKey: .source), !savedSource.isEmpty {
            sources = [savedSource]
        }
        target = try values.decodeIfPresent(String.self, forKey: .target) ?? ""
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(source, forKey: .source)
        try values.encode(sources, forKey: .sources)
        try values.encode(target, forKey: .target)
        try values.encode(isEnabled, forKey: .isEnabled)
    }
}

public struct VoiceVocabularyResult: Sendable, Equatable {
    public let text: String
    public let replacementCount: Int
}

public enum VoiceVocabularyError: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Cache only the latest rule snapshot. Regex is immutable; all cache access is locked.
private final class VoiceReplacementCache: @unchecked Sendable {
    struct Compiled: Sendable {
        let regex: NSRegularExpression
        let template: String
    }
    private let lock = NSLock()
    private var snapshot: [VoiceReplacement]?
    private var compiled: [Compiled] = []

    func rules(for input: [VoiceReplacement]) -> [Compiled]? {
        lock.lock()
        defer { lock.unlock() }
        if snapshot == input { return compiled }
        snapshot = input
        compiled = input.filter { $0.isEnabled }.flatMap { rule in
            rule.sources.compactMap { source -> Compiled? in
                let characters = source.filter { !$0.isWhitespace }
                guard !characters.isEmpty, !rule.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let core = characters.map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s*")
                let pattern = "(?<![a-zA-Z0-9])" + core + "(?![a-zA-Z0-9])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
                return Compiled(regex: regex, template: NSRegularExpression.escapedTemplate(for: rule.target))
            }
        }
        return compiled
    }
}

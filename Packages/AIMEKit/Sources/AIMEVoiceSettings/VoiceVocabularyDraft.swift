public import AIMEVoice
public import Foundation

/// An unsaved dictionary edit. Invalid changes leave the draft intact.
public struct VoiceVocabularyDraft: Equatable, Sendable {
    public private(set) var value: VoiceVocabulary

    public init(_ value: VoiceVocabulary) { self.value = value }

    public mutating func addWord(_ text: String) throws {
        let word = try checkedWord(text)
        value.hotwords.append(word)
    }

    public mutating func updateWord(at index: Int, to text: String) throws {
        try requireWord(at: index)
        value.hotwords[index] = try checkedWord(text, replacing: index)
    }

    public mutating func removeWord(at index: Int) throws {
        try requireWord(at: index)
        value.hotwords.remove(at: index)
    }

    private func requireWord(at index: Int) throws {
        guard value.hotwords.indices.contains(index) else {
            throw VoiceVocabularyError.invalid("词条已变化，请重新选择")
        }
    }

    public mutating func saveRule(_ original: VoiceReplacement, pendingTrigger: String = "") throws {
        var rule = original
        let pending = pendingTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { rule.sources.append(pending) }
        guard !rule.sources.isEmpty, rule.sources.count <= VoiceReplacement.maximumSources,
              rule.sources.allSatisfy({ !Self.triggerKey($0).isEmpty && $0.count <= 80 }),
              !rule.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.target.count <= 500 else {
            throw VoiceVocabularyError.invalid("请填写 1–5 个触发词和替换内容；触发词最多 80 字，替换内容最多 500 字")
        }
        var seen = Set(value.replacements.filter { $0.id != rule.id }.flatMap(\.sources).map(Self.triggerKey))
        for source in rule.sources {
            guard seen.insert(Self.triggerKey(source)).inserted else {
                throw VoiceVocabularyError.invalid("触发词重复（忽略大小写和空白）")
            }
        }
        if let index = value.replacements.firstIndex(where: { $0.id == rule.id }) {
            value.replacements[index] = rule
        } else {
            guard value.replacements.count < 200 else { throw VoiceVocabularyError.invalid("纠错规则最多 200 条") }
            value.replacements.append(rule)
        }
    }

    public mutating func removeRule(id: UUID) {
        value.replacements.removeAll { $0.id == id }
    }

    public func validatedValue() throws -> VoiceVocabulary {
        var seen = Set<String>()
        for word in value.hotwords {
            guard seen.insert(word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted else {
                throw VoiceVocabularyError.invalid("词条已存在，请删除重复词条")
            }
        }
        try value.validate()
        var normalized = value
        normalized.hotwords = value.normalizedHotwords
        return normalized
    }

    static func triggerKey(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }

    private func checkedWord(_ text: String, replacing index: Int? = nil) throws -> String {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw VoiceVocabularyError.invalid("请输入词条") }
        guard word.count <= 80, !word.contains(where: \.isNewline) else {
            throw VoiceVocabularyError.invalid("词条需为单行，最多 80 个字符")
        }
        guard !value.hotwords.enumerated().contains(where: {
            $0.offset != index && $0.element.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == word.lowercased()
        }) else { throw VoiceVocabularyError.invalid("词条已存在") }
        guard index != nil || value.hotwords.count < 500 else {
            throw VoiceVocabularyError.invalid("识别词条最多 500 个")
        }
        return word
    }
}

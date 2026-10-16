import AIMEVoice
import AIMEVoiceSettings
import XCTest

final class VoiceVocabularyDraftTests: XCTestCase {
    func testAddingWordTrimsItAndRejectsCaseInsensitiveDuplicateWithoutChangingDraft() throws {
        var draft = VoiceVocabularyDraft(VoiceVocabulary())
        try draft.addWord(" GitHub ")
        XCTAssertEqual(draft.value.hotwords, ["GitHub"])
        XCTAssertThrowsError(try draft.addWord("github"))
        XCTAssertEqual(draft.value.hotwords, ["GitHub"])
    }
    func testEditingAndRemovingWordsPreservesUnrelatedEntriesAndRejectsInvalidEdits() throws {
        var vocabulary = VoiceVocabulary()
        vocabulary.hotwords = ["GitHub", "Codex"]
        var draft = VoiceVocabularyDraft(vocabulary)
        try draft.updateWord(at: 0, to: " GitLab ")
        XCTAssertEqual(draft.value.hotwords, ["GitLab", "Codex"])
        XCTAssertThrowsError(try draft.updateWord(at: 0, to: "codex"))
        XCTAssertThrowsError(try draft.updateWord(at: 9, to: "Lost"))
        XCTAssertEqual(draft.value.hotwords, ["GitLab", "Codex"])
        try draft.removeWord(at: 0)
        XCTAssertEqual(draft.value.hotwords, ["Codex"])
    }
    func testRulesAcceptFiveTriggersAndRejectSixthOrDuplicateWithoutMutation() throws {
        var draft = VoiceVocabularyDraft(VoiceVocabulary())
        var rule = VoiceReplacement(sources: ["git hub", "吉特哈布", "吉哈布", "git哈布"], target: "GitHub")
        try draft.saveRule(rule, pendingTrigger: " 吉特哈伯 ")
        XCTAssertEqual(draft.value.replacements[0].sources.count, 5)
        XCTAssertEqual(draft.value.apply(to: "打开git hub").text, "打开GitHub")
        rule = draft.value.replacements[0]
        let saved = draft.value
        XCTAssertThrowsError(try draft.saveRule(rule, pendingTrigger: "第六个"))
        XCTAssertThrowsError(try draft.saveRule(VoiceReplacement(source: "GIT HUB", target: "Other")))
        XCTAssertEqual(draft.value, saved)
        rule.target = "GitLab"
        try draft.saveRule(rule)
        XCTAssertEqual(draft.value.replacements.count, 1)
        XCTAssertEqual(draft.value.replacements[0].target, "GitLab")
        draft.removeRule(id: rule.id)
        XCTAssertTrue(draft.value.replacements.isEmpty)
    }
    func testApplyingDraftValidatesSavedValuesAndNormalizesWithoutChangingOriginal() throws {
        var original = VoiceVocabulary()
        original.hotwords = ["  GitHub  ", "Codex"]
        let draft = VoiceVocabularyDraft(original)
        XCTAssertEqual(try draft.validatedValue().hotwords, ["GitHub", "Codex"])
        XCTAssertEqual(draft.value, original)
        original.hotwords = ["GitHub", " github "]
        XCTAssertThrowsError(try VoiceVocabularyDraft(original).validatedValue())
        original.hotwords = [String(repeating: "x", count: 81)]
        XCTAssertThrowsError(try VoiceVocabularyDraft(original).validatedValue())
    }
    func testWordLimitsRejectInvalidInputAndAllowEditingAtCapacity() throws {
        var vocabulary = VoiceVocabulary()
        vocabulary.hotwords = (0..<500).map { "词条\($0)" }
        var draft = VoiceVocabularyDraft(vocabulary)
        for invalid in ["", "   ", "two\nlines", String(repeating: "字", count: 81), "新增词条"] {
            XCTAssertThrowsError(try draft.addWord(invalid))
            XCTAssertEqual(draft.value, vocabulary)
        }
        try draft.updateWord(at: 499, to: "替换现有词条")
        XCTAssertEqual(draft.value.hotwords.count, 500)
        XCTAssertEqual(draft.value.hotwords.last, "替换现有词条")
    }

    func testRuleCapacityAllowsEditingAndRejectsInvalidRuleAtomically() throws {
        var vocabulary = VoiceVocabulary()
        vocabulary.replacements = (0..<200).map { VoiceReplacement(source: "词条\($0)", target: "替换\($0)") }
        var draft = VoiceVocabularyDraft(vocabulary)
        XCTAssertThrowsError(try draft.saveRule(VoiceReplacement(source: "新增", target: "新词")))
        XCTAssertEqual(draft.value, vocabulary)
        var edited = vocabulary.replacements[0]
        edited.target = "已修改"
        edited.isEnabled = false
        try draft.saveRule(edited)
        XCTAssertEqual(draft.value.replacements.count, 200)
        XCTAssertEqual(draft.value.replacements[0], edited)
        let saved = draft.value
        for invalid in [VoiceReplacement(source: "", target: "有效"),
                        VoiceReplacement(source: "有效", target: " "),
                        VoiceReplacement(sources: ["same word", "SAMEWORD"], target: "有效")] {
            XCTAssertThrowsError(try draft.saveRule(invalid))
            XCTAssertEqual(draft.value, saved)
        }
    }
}

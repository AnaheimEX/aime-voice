import AIMEVoice
import AIMEVoiceSettings
import Foundation
import XCTest

final class VoiceSettingsOperationsTests: XCTestCase {
    func testEachRoleRestoresItsOwnCustomAddressModelAndKeyAfterPresetRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles: [(presets: [VoiceProviderPreset], endpoint: WritableKeyPath<VoiceSettings, VoiceEndpoint>,
                     profiles: WritableKeyPath<VoiceSettings, VoiceProviderProfiles>)] = [
            (VoiceProviderPreset.speech, \VoiceSettings.asr, \VoiceSettings.asrProfiles),
            (VoiceProviderPreset.text, \VoiceSettings.llm, \VoiceSettings.llmProfiles),
            (VoiceProviderPreset.decision, \VoiceSettings.decision, \VoiceSettings.decisionProfiles),
        ]
        for (index, role) in roles.enumerated() {
            let url = root.appendingPathComponent("role-\(index)/settings.json")
            let custom = try XCTUnwrap(role.presets.first { $0.id == "openai-custom" })
            let alternate = try XCTUnwrap(role.presets.first { $0.id != custom.id })
            var profiles = VoiceProviderProfiles()
            var endpoint = profiles.select(custom, current: VoiceEndpoint(), inferredID: nil)
            endpoint.baseURL = "https://example.invalid/v1"
            endpoint.model = "fixture-model-\(index)"
            endpoint.apiKey = "fixture-key-\(index)"
            let expected = endpoint
            var settings = VoiceSettings()
            settings[keyPath: role.endpoint] = endpoint
            settings[keyPath: role.profiles] = profiles
            try settings.save(to: url)
            settings = VoiceSettings.load(from: url)
            profiles = settings[keyPath: role.profiles]
            endpoint = profiles.select(alternate, current: settings[keyPath: role.endpoint], inferredID: nil)
            endpoint.apiKey = "alternate-fixture-key"
            settings[keyPath: role.endpoint] = endpoint
            settings[keyPath: role.profiles] = profiles
            try settings.save(to: url)
            settings = VoiceSettings.load(from: url)
            profiles = settings[keyPath: role.profiles]
            endpoint = profiles.select(custom, current: settings[keyPath: role.endpoint], inferredID: nil)
            XCTAssertEqual(endpoint, expected)
            XCTAssertEqual(profiles.entries[alternate.id]?.apiKey, "alternate-fixture-key")
            settings[keyPath: role.endpoint] = endpoint
            settings[keyPath: role.profiles] = profiles
            try settings.save(to: url)
            let restored = VoiceSettings.load(from: url)
            XCTAssertEqual(restored[keyPath: role.endpoint], expected)
            XCTAssertEqual(restored[keyPath: role.profiles].selectedID, custom.id)
            XCTAssertEqual(restored[keyPath: role.profiles].entries[alternate.id]?.apiKey, "alternate-fixture-key")
        }
    }

    func testDictionaryDraftAndAllRoleProfilesSurviveConfigurationRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings-fixture.json")
        var settings = VoiceSettings()
        settings.mode = "custom"
        settings.polishStyle = .standard
        settings.customPrompt = "保留专名"
        settings.recordingGesture = "hold"
        var draft = VoiceVocabularyDraft(settings.vocabulary)
        try draft.addWord("GitHub")
        try draft.saveRule(VoiceReplacement(sources: ["git hub", "吉特哈布"], target: "GitHub"))
        settings.vocabulary = try draft.validatedValue()
        let custom = try XCTUnwrap(VoiceProviderPreset.text.first { $0.id == "openai-custom" })
        settings.llm = settings.llmProfiles.select(custom, current: settings.llm, inferredID: nil)
        settings.llm.apiKey = "fixture-key"
        settings.decision.apiKey = "different-fixture-key"
        try settings.save(to: url)
        let restored = VoiceSettings.load(from: url)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.vocabulary.apply(to: "打开吉特哈布").text, "打开GitHub")
    }
    func testSavingRestrictsDirectoryAndFilePermissionsOnCreationAndReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        let url = directory.appendingPathComponent("settings.json")
        var settings = VoiceSettings()
        settings.customPrompt = "初始值"
        try settings.save(to: url)
        for path in [directory, url] {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, path == directory ? 0o700 : 0o600)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        settings.customPrompt = "替换后的值"
        try settings.save(to: url)
        XCTAssertEqual(VoiceSettings.load(from: url).customPrompt, "替换后的值")
        for path in [directory, url] {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, path == directory ? 0o700 : 0o600)
        }
    }

    func testRejectedSaveKeepsLastValidConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        var saved = VoiceSettings()
        saved.customPrompt = "必须保留"
        saved.polishStyle = .standard
        try saved.save(to: url)
        var invalid = saved
        invalid.customPrompt = "不应落盘"
        invalid.cancelShortcut = invalid.toggleShortcut
        XCTAssertThrowsError(try invalid.save(to: url))
        XCTAssertEqual(VoiceSettings.load(from: url), saved)
        invalid = saved
        invalid.vocabulary.replacements = [VoiceReplacement(source: "", target: "无效")]
        XCTAssertThrowsError(try invalid.save(to: url))
        XCTAssertEqual(VoiceSettings.load(from: url), saved)
    }

    func testTranslateSettingsRoundTripAndDoNotReplacePostRecognitionLanguage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        var settings = VoiceSettings()
        settings.enabled = true
        settings.mode = "translate"
        settings.targetLanguage = "法文"
        settings.translateShortcut = "Control+Alt+y"
        settings.translateTargetLanguage = .japanese
        settings.translatePromptJa = "只输出日文译文"
        try settings.save(to: url)
        let restored = VoiceSettings.load(from: url)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.mode, "translate")
        XCTAssertEqual(restored.targetLanguage, "法文")
        XCTAssertEqual(restored.translateTargetLanguage, .japanese)
        XCTAssertEqual(restored.effectiveTranslatePrompt, "只输出日文译文")
        XCTAssertFalse(restored.effectiveTranslatePrompt.contains("法文"))
        let shortcuts = try JSONDecoder().decode(VoiceShortcutConfiguration.self, from: Data(contentsOf: url))
        XCTAssertEqual(shortcuts.translateShortcut, "Control+Alt+y")
        XCTAssertEqual(shortcuts.rewriteShortcut, "Control+Alt+r")
        let legacy = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"mode":"translate","targetLanguage":"法文"}"#.utf8))
        XCTAssertEqual(legacy.mode, "translate")
        XCTAssertEqual(legacy.targetLanguage, "法文")
        XCTAssertEqual(legacy.translateShortcut, "Control+Alt+t")
        XCTAssertEqual(legacy.translateTargetLanguage, .english)
        XCTAssertEqual(legacy.translatePromptEn, "")
        XCTAssertEqual(legacy.translatePromptJa, "")
        let unknown = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"translateTargetLanguage":"fr"}"#.utf8))
        XCTAssertEqual(unknown.translateTargetLanguage, .english)
    }

    func testTranslateShortcutRejectsCollisionsWithRecordRewriteAndAssistant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        var saved = VoiceSettings()
        saved.translatePromptEn = "保留"
        try saved.save(to: url)
        let collisions = [
            saved.toggleShortcut, saved.cancelShortcut, saved.rewriteShortcut,
            "Control+Alt+p", "Return", "Escape", "not a shortcut",
        ]
        for shortcut in collisions {
            var invalid = saved
            invalid.translateShortcut = shortcut
            XCTAssertThrowsError(try invalid.save(to: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("翻译"))
            }
            XCTAssertEqual(VoiceSettings.load(from: url).translatePromptEn, "保留")
            XCTAssertEqual(VoiceSettings.load(from: url).translateShortcut, "Control+Alt+t")
        }
        var rewrite = saved
        rewrite.rewriteShortcut = "Control+Alt+t"
        XCTAssertThrowsError(try rewrite.save(to: url))
        XCTAssertEqual(VoiceSettings.load(from: url).rewriteShortcut, "Control+Alt+r")
    }

    func testTranslatePromptFollowsTheSelectedLanguageAndKeepsTheOtherCustomPrompt() {
        var settings = VoiceSettings()
        XCTAssertEqual(settings.effectiveTranslatePrompt, VoiceTranslate.englishInstructions)
        XCTAssertTrue(settings.effectiveTranslatePrompt.contains("英文"))
        XCTAssertFalse(settings.effectiveTranslatePrompt.contains("日文"))
        settings.translateTargetLanguage = .japanese
        XCTAssertEqual(settings.effectiveTranslatePrompt, VoiceTranslate.japaneseInstructions)
        XCTAssertTrue(settings.effectiveTranslatePrompt.contains("日文"))
        XCTAssertFalse(settings.effectiveTranslatePrompt.contains("英文"))
        settings.setTranslatePrompt("  \n", for: .japanese)
        XCTAssertEqual(settings.translatePromptJa, "")
        XCTAssertEqual(settings.effectiveTranslatePrompt, VoiceTranslate.japaneseInstructions)
        settings.setTranslatePrompt(VoiceTranslate.englishInstructions, for: .english)
        XCTAssertEqual(settings.translatePromptEn, "")
        settings.setTranslatePrompt("译成英文，只输出译文", for: .english)
        settings.setTranslatePrompt("訳して。訳文だけ。", for: .japanese)
        settings.translateTargetLanguage = .english
        let english = VoiceTranslate.completionRequest(text: "你好，ChatGPT", settings: settings)
        XCTAssertEqual(english.instructions, "译成英文，只输出译文")
        XCTAssertEqual(english.text, "你好，ChatGPT")
        settings.translateTargetLanguage = .japanese
        let japanese = VoiceTranslate.completionRequest(text: "你好，ChatGPT", settings: settings)
        XCTAssertEqual(japanese.instructions, "訳して。訳文だけ。")
        XCTAssertEqual(japanese.text, "你好，ChatGPT")
        XCTAssertNotEqual(english.instructions, japanese.instructions)
        settings.targetLanguage = "法文"
        settings.mode = "translate"
        XCTAssertEqual(settings.effectiveTranslatePrompt, "訳して。訳文だけ。")
        XCTAssertEqual(settings.translatePromptEn, "译成英文，只输出译文")
    }

    func testFieldTranslateFailsBeforeNetworkWhenTheTextModelIsMissing() async {
        var settings = VoiceSettings()
        settings.mode = "translate"
        settings.targetLanguage = "法文"
        settings.translateTargetLanguage = .english
        settings.translatePromptEn = "EN_PROMPT_SENTINEL"
        settings.decisionMode = "accelerate"
        settings.decision = VoiceEndpoint(baseURL: "http://127.0.0.1:9/v1", model: "forbidden-decision", apiKey: "test")
        do {
            _ = try await VoiceProcessor().translate("你好", settings: settings)
            XCTFail("missing text model must fail before a request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("润色模型"))
        }
    }

    func testMissingOrMalformedFileLoadsDefaultsAtExplicitPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        XCTAssertEqual(VoiceSettings.load(from: url), VoiceSettings())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{invalid-json".utf8).write(to: url)
        XCTAssertEqual(VoiceSettings.load(from: url), VoiceSettings())
    }
}

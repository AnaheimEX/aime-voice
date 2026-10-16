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

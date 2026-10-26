public import Foundation
import Darwin

public struct VoiceEndpoint: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var protocolType: String
    public var resourceID: String
    public var appID: String
    public var speechAuthMode: String
    public var decisionThreshold = 0.5
    public var decisionActionThreshold = 0.5
    public var effectiveDecisionThreshold: Double { Self.probability(decisionThreshold) }
    public var effectiveDecisionActionThreshold: Double { Self.probability(decisionActionThreshold) }
    private static func probability(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }

    public init(baseURL: String = "", model: String = "", apiKey: String = "",
                protocolType: String = "auto", resourceID: String = "", appID: String = "", speechAuthMode: String = "api-key") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.protocolType = protocolType
        self.resourceID = resourceID
        self.appID = appID
        self.speechAuthMode = speechAuthMode
    }

    public var isConfigured: Bool {
        if resolvedProtocol == .apple { return true }
        if resolvedProtocol == .layaPredict { return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if resolvedProtocol == .volcStreaming || resolvedProtocol == .volcFlash {
            return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (speechAuthMode == "api-key" || (speechAuthMode == "legacy"
                    && !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isEmpty
    }

    private enum CodingKeys: String, CodingKey { case baseURL, model, apiKey, protocolType, resourceID, appID, speechAuthMode, decisionThreshold, decisionActionThreshold }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? model
        decisionThreshold = try values.decodeIfPresent(Double.self, forKey: .decisionThreshold) ?? decisionThreshold
        decisionActionThreshold = try values.decodeIfPresent(Double.self, forKey: .decisionActionThreshold) ?? decisionActionThreshold
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        protocolType = try values.decodeIfPresent(String.self, forKey: .protocolType) ?? protocolType
        resourceID = try values.decodeIfPresent(String.self, forKey: .resourceID) ?? resourceID
        appID = try values.decodeIfPresent(String.self, forKey: .appID) ?? appID
        speechAuthMode = try values.decodeIfPresent(String.self, forKey: .speechAuthMode)
            ?? (appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "api-key" : "legacy")
    }
}

public enum VoicePolishStyle: String, Codable, Sendable {
    case standard, chat, custom
}

/// Each role owns its own profiles; credentials never spill into another preset.
public struct VoiceProviderProfiles: Codable, Sendable, Equatable {
    public var selectedID: String?
    public var entries: [String: VoiceEndpoint] = [:]

    public init() {}

    public mutating func select(_ preset: VoiceProviderPreset, current: VoiceEndpoint, inferredID: String?) -> VoiceEndpoint {
        let previousID = selectedID ?? inferredID
        if let previousID { entries[previousID] = current }
        selectedID = preset.id
        let restored = entries[preset.id] ?? preset.endpoint
        return preset.id == "fish" ? restored.normalizedFishASR : restored
    }
}

public enum VoiceSpeechBackend: String, Codable, Sendable {
    case local, apple, cloud, interfaze
}

public struct VoiceSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var toggleShortcut = VoiceShortcutConfiguration().toggleShortcut
    public var cancelShortcut = VoiceShortcutConfiguration().cancelShortcut
    public var rewriteShortcut = VoiceShortcutConfiguration().rewriteShortcut
    public var translateShortcut = VoiceShortcutConfiguration().translateShortcut
    /// Selection hotkey target. Not the free-text language used after speech recognition.
    public var translateTargetLanguage: VoiceTranslateLanguage = .english
    public var translatePromptEn = ""
    public var translatePromptJa = ""
    public var recordingGesture = "toggle"
    public var speechBackend: VoiceSpeechBackend = .local
    public var interfazeAPIKey = ""
    public var localSpeechModel: LocalSpeechModel = .whisperSmall
    public var asr = VoiceEndpoint()
    public var llm = VoiceEndpoint()
    public var asrProfiles = VoiceProviderProfiles()
    public var llmProfiles = VoiceProviderProfiles()
    public var decisionProfiles = VoiceProviderProfiles()
    public var volcSecondPass = true
    public var language: String { "auto" }
    public var mode = "polish"
    public var targetLanguage = "英文"
    public var customPrompt = ""
    public var polishPrompt = "" { didSet { polishStyle = nil } }
    /// Persist the chosen policy; old settings infer it once from their saved prompt.
    public var polishStyle: VoicePolishStyle?
    public var effectivePolishStyle: VoicePolishStyle {
        polishStyle ?? VoiceProcessor.inferredPolishStyle(polishPrompt)
    }

    public func savedTranslatePrompt(for language: VoiceTranslateLanguage) -> String {
        switch language {
        case .english: translatePromptEn
        case .japanese: translatePromptJa
        }
    }

    /// Empty or whitespace-only custom text uses the built-in prompt for the active language.
    public var effectiveTranslatePrompt: String {
        let saved = savedTranslatePrompt(for: translateTargetLanguage).trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? VoiceTranslate.instructions(for: translateTargetLanguage) : saved
    }

    public var activeTranslatePromptIsCustom: Bool {
        !savedTranslatePrompt(for: translateTargetLanguage).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func setTranslatePrompt(_ prompt: String, for language: VoiceTranslateLanguage) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trimmed == VoiceTranslate.instructions(for: language) ? "" : trimmed
        switch language {
        case .english: translatePromptEn = stored
        case .japanese: translatePromptJa = stored
        }
    }
    public var decisionMode = "off"
    public var decisionProtocol = "jev"
    public var decisionBudgetMilliseconds = 600
    public var effectiveDecisionBudgetMilliseconds: Int {
        decisionProtocol == "laya-predict" ? min(1000, max(500, decisionBudgetMilliseconds))
            : min(2000, max(100, decisionBudgetMilliseconds))
    }
    public var decision = VoiceEndpoint()
    /// Voice-only content; persisted here, independently of AIMECore's Rime workspace.
    public var vocabulary = VoiceVocabulary()

    public init() {}

    public static let changedNotification = "app.zool.aime.voice-settings-changed"

    public static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/AIME/voice-settings.json")
    }

    public static func load() -> VoiceSettings { load(from: settingsURL) }

    public static func load(from url: URL) -> VoiceSettings {
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        settings.asr = settings.asr.normalizedFishASR
        if let fish = settings.asrProfiles.entries["fish"] {
            settings.asrProfiles.entries["fish"] = fish.normalizedFishASR
        }
        return settings
    }

    public func save() throws { try save(to: Self.settingsURL) }

    public func save(to url: URL) throws {
        try vocabulary.validate()
        try VoiceShortcutConfiguration.validate(toggle: toggleShortcut, cancel: cancelShortcut,
                                                rewrite: rewriteShortcut, translate: translateShortcut)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(self)
        let temporary = directory.appendingPathComponent(".voice-settings-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var keepTemporary = true
        defer { if keepTemporary { try? FileManager.default.removeItem(at: temporary) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        keepTemporary = false
    }

    private enum CodingKeys: String, CodingKey {
        case volcSecondPass, enabled, toggleShortcut, cancelShortcut, rewriteShortcut, translateShortcut, recordingGesture, asr, llm, mode, targetLanguage, customPrompt, polishPrompt
        case translateTargetLanguage, translatePromptEn, translatePromptJa
        case decisionMode, decisionProtocol, decisionBudgetMilliseconds, decision
        case vocabulary, polishStyle, localSpeechModel, speechBackend, interfazeAPIKey
        case asrProfiles, llmProfiles, decisionProfiles
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volcSecondPass = try container.decodeIfPresent(Bool.self, forKey: .volcSecondPass) ?? true
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        toggleShortcut = try container.decodeIfPresent(String.self, forKey: .toggleShortcut) ?? toggleShortcut
        cancelShortcut = try container.decodeIfPresent(String.self, forKey: .cancelShortcut) ?? cancelShortcut
        rewriteShortcut = try container.decodeIfPresent(String.self, forKey: .rewriteShortcut) ?? rewriteShortcut
        translateShortcut = try container.decodeIfPresent(String.self, forKey: .translateShortcut) ?? translateShortcut
        recordingGesture = try container.decodeIfPresent(String.self, forKey: .recordingGesture) ?? recordingGesture
        speechBackend = try container.decodeIfPresent(VoiceSpeechBackend.self, forKey: .speechBackend) ?? speechBackend
        interfazeAPIKey = try container.decodeIfPresent(String.self, forKey: .interfazeAPIKey) ?? interfazeAPIKey
        localSpeechModel = try container.decodeIfPresent(LocalSpeechModel.self, forKey: .localSpeechModel) ?? localSpeechModel
        asr = try container.decodeIfPresent(VoiceEndpoint.self, forKey: .asr) ?? asr
        llm = try container.decodeIfPresent(VoiceEndpoint.self, forKey: .llm) ?? llm
        asrProfiles = try container.decodeIfPresent(VoiceProviderProfiles.self, forKey: .asrProfiles) ?? asrProfiles
        llmProfiles = try container.decodeIfPresent(VoiceProviderProfiles.self, forKey: .llmProfiles) ?? llmProfiles
        decisionProfiles = try container.decodeIfPresent(VoiceProviderProfiles.self, forKey: .decisionProfiles) ?? decisionProfiles
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? mode
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? targetLanguage
        if let storedLanguage = try container.decodeIfPresent(String.self, forKey: .translateTargetLanguage),
           let language = VoiceTranslateLanguage(stored: storedLanguage) {
            translateTargetLanguage = language
        }
        translatePromptEn = try container.decodeIfPresent(String.self, forKey: .translatePromptEn) ?? translatePromptEn
        translatePromptJa = try container.decodeIfPresent(String.self, forKey: .translatePromptJa) ?? translatePromptJa
        customPrompt = try container.decodeIfPresent(String.self, forKey: .customPrompt) ?? customPrompt
        polishPrompt = try container.decodeIfPresent(String.self, forKey: .polishPrompt) ?? polishPrompt
        polishStyle = try container.decodeIfPresent(VoicePolishStyle.self, forKey: .polishStyle) ?? effectivePolishStyle
        decisionMode = try container.decodeIfPresent(String.self, forKey: .decisionMode) ?? decisionMode
        decisionProtocol = try container.decodeIfPresent(String.self, forKey: .decisionProtocol) ?? decisionProtocol
        decisionBudgetMilliseconds = try container.decodeIfPresent(Int.self, forKey: .decisionBudgetMilliseconds) ?? decisionBudgetMilliseconds
        decision = try container.decodeIfPresent(VoiceEndpoint.self, forKey: .decision) ?? decision
        vocabulary = try container.decodeIfPresent(VoiceVocabulary.self, forKey: .vocabulary) ?? vocabulary
    }
}

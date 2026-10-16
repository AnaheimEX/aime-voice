import AIMEVoice
import AppKit
import Foundation
public import SwiftUI

public struct VoiceSettingsPane: View {
    private let style: VoiceSettingsStyle

    public init(style: VoiceSettingsStyle) { self.style = style }

    @State private var settings = VoiceSettings.load()
    @State private var saveMessage: String?
    @State private var saveFailed = false
    @State private var showingPolishPrompt = false
    @State private var showingVocabulary = false

    public var body: some View {
        Form {
            Section {
                VoicePaneHeader(title: "语音输入", subtitle: "让语音变成文字自己上屏", symbol: "mic")
            }
            Section("语音输入") {
                Toggle("启用语音输入", isOn: $settings.enabled)
                Picker("录音方式", selection: $settings.recordingGesture) {
                    Text("按一下开始，再按一下结束").tag("toggle")
                    Text("按住说话，松开结束").tag("hold")
                }
                LabeledContent(settings.recordingGesture == "hold" ? "按住录音" : "开始／结束录音") {
                    HStack {
                        VoiceKeyRecorder(value: settings.toggleShortcut) { settings.toggleShortcut = $0 }
                        Button("恢复默认") { settings.toggleShortcut = VoiceSettings().toggleShortcut }.buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("语音改写")
                        Text("说出修改要求").font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                    VoiceKeyRecorder(value: settings.rewriteShortcut) { settings.rewriteShortcut = $0 }
                        .fixedSize()
                    Button("恢复默认") { settings.rewriteShortcut = VoiceSettings().rewriteShortcut }
                        .buttonStyle(.borderless).fixedSize()
                }
                LabeledContent("辅助功能") {
                    Button("打开辅助功能设置") {
                        DistributedNotificationCenter.default().postNotificationName(
                            .init("app.zool.aime.voice.requestAccessibility"), object: nil, userInfo: nil, deliverImmediately: true)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                LabeledContent("取消语音输入") {
                    HStack {
                        VoiceKeyRecorder(value: settings.cancelShortcut) { settings.cancelShortcut = $0 }
                        Button("恢复默认") { settings.cancelShortcut = VoiceSettings().cancelShortcut }.buttonStyle(.borderless)
                    }
                }
            }
            Section("语音识别") {
                Picker("识别方式", selection: $settings.speechBackend) {
                    Text("本地模型 · Cohere / Whisper").tag(VoiceSpeechBackend.local)
                    Text("macOS 本机识别").tag(VoiceSpeechBackend.apple)
                    Text("云端服务 · 小米 / 豆包等").tag(VoiceSpeechBackend.cloud)
                    Text("Interfaze 云端").tag(VoiceSpeechBackend.interfaze)
                }
                if settings.speechBackend == .local {
                    LocalSpeechModelControls(model: $settings.localSpeechModel)
                } else if settings.speechBackend == .apple {
                    Text("使用 macOS 系统语音识别，跟随系统首选语言；要求该语言支持设备端识别并已安装语音资源，不回退云端。首次使用需授权语音识别。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if settings.speechBackend == .cloud {
                    VoiceEndpointFields(endpoint: $settings.asr, profiles: $settings.asrProfiles, purpose: .speech)
                } else {
                    SecureField("Interfaze API Key", text: $settings.interfazeAPIKey)
                    Text("使用 interfaze-1 纯语音识别。停录后将音频发送至 Interfaze，并请求零数据保留；按服务额度计费。润色、决策和最终词典替换继续使用当前设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VoiceModelTestControls(settings: settings, kind: .speech)
            }
            Section("语音词典") {
                LabeledContent("语音词典内容") {
                    HStack {
                        Text("\(settings.vocabulary.normalizedHotwords.count) 个词条 · \(settings.vocabulary.replacements.filter(\.isEnabled).count) 条纠错规则")
                            .foregroundStyle(.secondary)
                        Button("管理语音词典") { showingVocabulary = true }
                            .accessibilityIdentifier("voice-vocabulary-manage")
                    }
                }
                .sheet(isPresented: $showingVocabulary) {
                    VoiceVocabularyEditor(vocabulary: $settings.vocabulary)
                }
                Text("与文字词库独立维护。Cohere、Whisper 和 Interfaze 不使用热词，豆包流式按预算提交热词。纠错只在润色前替换一次。整段就是一条已启用纠错触发词时，不论长短，替换后直接上屏。热词只在整段一至四字且完全一致时直接上屏。句子里夹着的词，以及更长的热词，用替换后的文字润色，不再做第二次替换。不会修改键盘候选、短语或词频。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文字整理") {
                Picker("处理方式", selection: $settings.mode) {
                    Text("语音润色").tag("polish")
                    Text("翻译").tag("translate")
                    Text("自定义转换").tag("custom")
                    Text("仅转写").tag("raw")
                }
                if settings.mode == "polish" {
                    LabeledContent("润色提示词") {
                        HStack {
                            Text(settings.polishPrompt.isEmpty ? "默认规则" : "自定义规则")
                                .foregroundStyle(.secondary)
                            Button("编辑提示词…") { showingPolishPrompt = true }
                                .buttonStyle(.bordered)
                                .sheet(isPresented: $showingPolishPrompt) {
                                    VoicePolishPromptEditor(settings: $settings)
                                }
                        }
                    }
                }
                if settings.mode == "translate" {
                    LabeledContent("目标语言") {
                        TextField("英文", text: $settings.targetLanguage).frame(maxWidth: 240)
                    }
                }
                if settings.mode == "custom" {
                    TextEditor(text: $settings.customPrompt).font(.body).frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                if settings.mode != "raw" {
                    VoiceEndpointFields(endpoint: $settings.llm, profiles: $settings.llmProfiles, purpose: .text)
                    VoiceModelTestControls(settings: settings, kind: .polish)
                    Text("润色与改写固定关闭思考模式。模型不支持关闭时，请选择非思考模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("决策加速") {
                Picker("运行方式", selection: $settings.decisionMode) {
                    Text("关闭").tag("off")
                    Text("仅观察决策").tag("shadow")
                    Text("允许采用加速结果").tag("accelerate")
                }
                VoiceEndpointFields(endpoint: $settings.decision, profiles: $settings.decisionProfiles, purpose: .decision, decisionProtocol: $settings.decisionProtocol)
                Stepper(value: $settings.decisionBudgetMilliseconds, in: settings.decisionProtocol == "laya-predict" ? 500...1000 : 100...2000, step: 100) {
                    Text("决策等待上限：\(settings.effectiveDecisionBudgetMilliseconds) ms")
                }
            .onChange(of: settings.decisionProtocol) {
                settings.decisionBudgetMilliseconds = settings.effectiveDecisionBudgetMilliseconds
            }
                VoiceModelTestControls(settings: settings, kind: .decision)
            }
            Section {
                HStack {
                    Button("保存设置", action: save).buttonStyle(.borderedProminent)
                    if let saveMessage {
                        Text(saveMessage).foregroundStyle(saveFailed ? style.warning : style.success).font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .environment(\.voiceSettingsStyle, style)
        .tint(style.accent)
    }

    private func save() {
        do {
            try settings.save()
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(VoiceSettings.changedNotification), object: nil, userInfo: nil, deliverImmediately: true)
            saveFailed = false
            saveMessage = "已保存"
        } catch {
            saveFailed = true
            saveMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

private enum VoiceEndpointPurpose { case speech, text, decision }

private struct VoiceEndpointFields: View {
    @Environment(\.voiceSettingsStyle) private var style
    @Binding var endpoint: VoiceEndpoint
    @Binding var profiles: VoiceProviderProfiles
    let purpose: VoiceEndpointPurpose
    @Binding var decisionProtocol: String
    init(endpoint: Binding<VoiceEndpoint>, profiles: Binding<VoiceProviderProfiles>, purpose: VoiceEndpointPurpose, decisionProtocol: Binding<String> = .constant("jev")) {
        self._endpoint = endpoint
        self._profiles = profiles
        self.purpose = purpose
        self._decisionProtocol = decisionProtocol
    }
    @State private var models: [String] = []
    @State private var message: String?
    @State private var failed = false
    @State private var fetching = false
    @State private var authenticating = false
    @State private var showingAPIKey = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()

    private var presets: [VoiceProviderPreset] {
        purpose == .speech ? VoiceProviderPreset.speech.filter { $0.id != "apple" } : purpose == .text ? VoiceProviderPreset.text : VoiceProviderPreset.decision
    }
    private var preset: VoiceProviderPreset? {
        if let id = profiles.selectedID, let selected = presets.first(where: { $0.id == id }) { return selected }
        return purpose == .decision ? VoiceProviderPreset.matchingDecision(endpoint, protocolName: decisionProtocol) : VoiceProviderPreset.matching(endpoint, speech: purpose == .speech)
    }
    private var isCodex: Bool { endpoint.resolvedProtocol == .codex }
    private var isApple: Bool { endpoint.resolvedProtocol == .apple }
    private var isVolc: Bool { [.volcStreaming, .volcFlash].contains(endpoint.resolvedProtocol) }
    private var usesLegacySpeechAuth: Bool { isVolc && endpoint.speechAuthMode == "legacy" }
    private var apiKeyTitle: String {
        usesLegacySpeechAuth ? "Access Token" : isVolc ? "语音 API Key" : endpoint.usesArk ? "方舟 API Key" : "API Key"
    }
    private var isCustomText: Bool { purpose == .text && (preset?.id == "openai-custom" || preset == nil) && !isCodex }
    private var isCustomSpeech: Bool { purpose == .speech && (preset?.id == "openai-custom" || preset == nil) }
    private var discoveryEndpoint: VoiceEndpoint {
        var value = endpoint
        if purpose == .decision { value.protocolType = decisionProtocol == "openai" ? "openai" : decisionProtocol == "laya-predict" ? "laya-predict" : "jev" }
        return value
    }

    var body: some View {
        Group {
            if !presets.isEmpty {
                LabeledContent("服务预设") {
                    Menu(preset?.title ?? "自定义配置") {
                        ForEach(presets) { item in Button(item.title) { choose(item) } }
                    }.frame(maxWidth: 320, alignment: .trailing)
                }
            }
            if isCustomText || isCustomSpeech || purpose == .decision {
                LabeledContent("接口地址") {
                    TextField("https://api.example.com/v1", text: $endpoint.baseURL)
                        .frame(maxWidth: 400)
                }
            }
            if isCodex {
                HStack {
                    Button("登录 ChatGPT 订阅") { login() }.disabled(fetching)
                    Button("刷新登录状态") { refreshAccount() }.disabled(fetching)
                    if authenticating {
                        Button("取消登录") { reset(); Task { await CodexSubscriptionClient.shared.cancelLogin() } }
                    }
                }
            } else if !isApple {
                if isVolc {
                    LabeledContent("鉴权方式") {
                        Picker("鉴权方式", selection: $endpoint.speechAuthMode) {
                        Text("语音服务 API Key").tag("api-key")
                            Text("App ID + Access Token（旧版控制台）").tag("legacy")
                        }
                        .labelsHidden().frame(maxWidth: 320)
                    }
                    if usesLegacySpeechAuth {
                        LabeledContent("App ID") {
                            TextField("旧版控制台 App ID", text: $endpoint.appID)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        }
                    }
                }
                LabeledContent(apiKeyTitle) {
                    HStack {
                        Group {
                            if showingAPIKey {
                                TextField(apiKeyTitle, text: $endpoint.apiKey)
                            } else {
                                SecureField(apiKeyTitle, text: $endpoint.apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button {
                            showingAPIKey.toggle()
                        } label: {
                            Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showingAPIKey ? "隐藏 \(apiKeyTitle)" : "显示 \(apiKeyTitle)")
                        .accessibilityLabel(showingAPIKey ? "隐藏 \(apiKeyTitle)" : "显示 \(apiKeyTitle)")
                    }
                    .frame(maxWidth: 320)
                }

            }
            if purpose == .decision && decisionProtocol == "laya-predict" {
                LabeledContent("服务端模型") {
                    TextField("服务端已加载的模型名称", text: $endpoint.model)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        .help("记录当前服务端模型；/predict协议不支持在请求中切换模型")
                }
                LabeledContent("润色阈值") {
                    HStack {
                        Slider(value: $endpoint.decisionThreshold, in: 0...1, step: 0.01)
                        Text(endpoint.effectiveDecisionThreshold.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit().frame(width: 40)
                    }.frame(maxWidth: 320)
                }
                LabeledContent("最低行动概率") {
                    HStack {
                        Slider(value: $endpoint.decisionActionThreshold, in: 0...1, step: 0.01)
                        Text(endpoint.effectiveDecisionActionThreshold.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit().frame(width: 40)
                    }.frame(maxWidth: 320)
                }
            } else if endpoint.resolvedProtocol == .fishASR {
                LabeledContent("模型") {
                    Picker("模型", selection: $endpoint.model) {
                        Text("transcribe-1-pro（推荐）").tag("transcribe-1-pro")
                        Text("transcribe-1").tag("transcribe-1")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            } else if VoiceModelDiscovery.supportsModelDiscovery(endpoint: discoveryEndpoint) {
                LabeledContent("模型") {
                    HStack {
                        TextField(endpoint.usesArk ? "Model ID 或 ep-接入点 ID" : "模型名称", text: $endpoint.model)
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(models, id: \.self) { model in Button(model) { endpoint.model = model } }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .fixedSize().disabled(models.isEmpty || fetching)
                        .accessibilityLabel("选择已拉取的模型")
                        Button(fetching ? "正在拉取…" : "拉取模型") { fetchModels() }
                            .fixedSize()
                            .disabled(fetching || endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: 320)
                }
            }
            if let message {
                Text(message).foregroundStyle(failed ? style.warning : .secondary).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: endpoint.baseURL) { showingAPIKey = false; configurationChanged() }
        .onChange(of: endpoint.apiKey) { configurationChanged() }
        .onChange(of: endpoint.protocolType) { showingAPIKey = false; configurationChanged() }
        .onChange(of: endpoint.speechAuthMode) { showingAPIKey = false; configurationChanged() }
        .onChange(of: endpoint.appID) { configurationChanged() }
        .onChange(of: endpoint.resourceID) { configurationChanged() }
        .onChange(of: decisionProtocol) { showingAPIKey = false; configurationChanged() }
        .onDisappear { showingAPIKey = false; reset() }
    }

    private func choose(_ preset: VoiceProviderPreset) {
        guard self.preset?.id != preset.id || endpoint.resolvedProtocol != preset.endpoint.resolvedProtocol else { return }
        showingAPIKey = false
        endpoint = profiles.select(preset, current: endpoint, inferredID: self.preset?.id)
        if purpose == .decision { decisionProtocol = preset.decisionProtocol }
        reset()
    }
    private func configurationChanged() {
        reset()
    }
    private func reset() {
        operationID = UUID()
        operation?.cancel(); operation = nil
        if authenticating { Task { await CodexSubscriptionClient.shared.cancelLogin() } }
        fetching = false; authenticating = false
        models = []; message = nil; failed = false
    }
    private func fetchModels() {
        reset()
        let id = operationID
        let requested = discoveryEndpoint
        fetching = true
        operation = Task { @MainActor in
            defer { if operationID == id { fetching = false } }
            do {
                let result = try await VoiceModelDiscovery.models(endpoint: requested, speech: purpose == .speech)
                guard operationID == id, !Task.isCancelled else { return }
                models = result
                message = "已获取 \(result.count) 个模型，请选择需要的模型"
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                failed = true; message = error.localizedDescription
            }
        }
    }
    private func login() {
        reset()
        let id = operationID
        fetching = true; authenticating = true
        operation = Task { @MainActor in
            defer { if operationID == id { fetching = false; authenticating = false } }
            do {
                let url = try await CodexSubscriptionClient.shared.login()
                guard operationID == id, !Task.isCancelled else { return }
                NSWorkspace.shared.open(url)
                try await CodexSubscriptionClient.shared.waitForLogin()
                let result = try await CodexSubscriptionClient.shared.models()
                guard operationID == id, !Task.isCancelled else { return }
                models = result
                message = "登录成功，已获取 \(result.count) 个模型，请选择需要的模型"
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                failed = true; message = error.localizedDescription
            }
        }
    }
    private func refreshAccount() {
        reset()
        let id = operationID
        fetching = true
        operation = Task { @MainActor in
            defer { if operationID == id { fetching = false } }
            do {
                let status = try await CodexSubscriptionClient.shared.accountStatus()
                guard operationID == id, !Task.isCancelled else { return }
                message = status
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                failed = true; message = error.localizedDescription
            }
        }
    }
}


private struct VoicePolishPromptEditor: View {
    @Environment(\.voiceSettingsStyle) private var style
    @Binding var settings: VoiceSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var errorMessage: String?

    init(settings: Binding<VoiceSettings>) {
        _settings = settings
        let saved = settings.wrappedValue.polishPrompt
        _draft = State(initialValue: saved.isEmpty ? VoiceProcessor.polishInstructions : saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("语音润色提示词").font(.title2.bold())
            TextEditor(text: $draft)
                .font(.body)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .frame(minHeight: 300)
                .accessibilityLabel("语音润色提示词内容")
            if let errorMessage {
                Text(errorMessage).foregroundStyle(style.warning).font(.callout)
            }
            HStack {
                Button("恢复默认") { draft = VoiceProcessor.polishInstructions; errorMessage = nil }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并生效") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
    }

    private func save() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["{selected}", "{clipboard}"].contains(where: { prompt.contains($0) }) else {
            errorMessage = "语音润色仅支持 {text}，不支持 {selected} 或 {clipboard}"
            return
        }
        var updated = settings
        updated.polishPrompt = prompt == VoiceProcessor.polishInstructions ? "" : prompt
        updated.polishStyle = updated.effectivePolishStyle
        do {
            try updated.save()
            settings = updated
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(VoiceSettings.changedNotification), object: nil)
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}


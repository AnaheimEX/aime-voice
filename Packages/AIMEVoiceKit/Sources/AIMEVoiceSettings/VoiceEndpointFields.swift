import AIMEVoice
import AppKit
import Foundation
import SwiftUI

enum VoiceEndpointPurpose { case speech, text, decision }

struct VoiceEndpointFields: View {
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
        // A URL typed while the menu still says "自定义配置" is the custom preset's; keep it for switching back.
        let typedCustom = purpose != .decision && !endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        endpoint = profiles.select(preset, current: endpoint, inferredID: self.preset?.id ?? (typedCustom ? "openai-custom" : nil))
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

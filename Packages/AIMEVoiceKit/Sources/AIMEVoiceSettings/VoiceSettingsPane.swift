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
                Text("与文字词库独立维护。Whisper 把热词放进识别提示，豆包流式按预算提交热词，Cohere 和 Interfaze 不使用热词；标准和聊天润色会把热词作为专名写法参考发给润色模型。纠错只在润色前替换一次。整段就是一条已启用纠错触发词时，不论长短，替换后直接上屏。热词只在整段一至四字且完全一致时直接上屏。句子里夹着的词，以及更长的热词，用替换后的文字润色，不再做第二次替换。不会修改键盘候选、短语或词频。")
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

import AIMEVoice
import Foundation
import SwiftUI

struct VoiceTranslatePromptEditor: View {
    @Environment(\.voiceSettingsStyle) private var style
    @Binding var settings: VoiceSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var errorMessage: String?
    private let language: VoiceTranslateLanguage

    init(settings: Binding<VoiceSettings>) {
        _settings = settings
        let language = settings.wrappedValue.translateTargetLanguage
        self.language = language
        let saved = settings.wrappedValue.savedTranslatePrompt(for: language)
        _draft = State(initialValue: saved.isEmpty ? VoiceTranslate.instructions(for: language) : saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("翻译提示词 · \(language.title)").font(.title2.bold())
            Text("只作用于翻译快捷键。英文和日文各自保存一份，切换目标语言时换用对应的一份。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .frame(minHeight: 300)
                .accessibilityLabel("翻译提示词内容")
            if let errorMessage {
                Text(errorMessage).foregroundStyle(style.warning).font(.callout)
            }
            HStack {
                Button("恢复默认") {
                    draft = VoiceTranslate.instructions(for: language)
                    errorMessage = nil
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并生效") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680, height: 560)
    }

    private func save() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["{selected}", "{clipboard}"].contains(where: { prompt.contains($0) }) else {
            errorMessage = "翻译提示词不支持 {selected} 或 {clipboard}"
            return
        }
        // Save only the prompt on top of what is on disk: the pane may hold unsaved edits.
        var updated = VoiceSettings.load()
        updated.setTranslatePrompt(prompt, for: language)
        do {
            try updated.save()
            settings.translateTargetLanguage = language
            settings.setTranslatePrompt(prompt, for: language)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(VoiceSettings.changedNotification), object: nil, userInfo: nil, deliverImmediately: true)
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

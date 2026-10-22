import AIMEVoice
import Foundation
import SwiftUI

struct VoicePolishPromptEditor: View {
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

import AIMEVoice
import AppKit
import Foundation
import SwiftUI

struct VoiceVocabularyEditor: View {
    @Environment(\.voiceSettingsStyle) private var style
    @Binding private var vocabulary: VoiceVocabulary
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VoiceVocabularyDraft
    @State private var search = ""
    @State private var newWord = ""
    @State private var editingWordIndex: Int?
    @State private var editingWord = ""
    @State private var editingRule: VoiceReplacement?
    @State private var triggerText = ""
    @State private var errorMessage: String?
    @State private var confirmingDiscard = false

    init(vocabulary: Binding<VoiceVocabulary>) {
        _vocabulary = vocabulary
        _draft = State(initialValue: VoiceVocabularyDraft(vocabulary.wrappedValue))
    }

    private var hasChanges: Bool {
        draft.value != vocabulary || !newWord.isEmpty || editingWordIndex != nil || editingRule != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("语音词典").font(.title2.bold())
                Spacer()
                Text("\(draft.value.hotwords.count) 个词条 · \(draft.value.replacements.count) 条规则")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("独立于文字词库。识别词条提示支持热词的识别服务。纠错在润色前替换一次。整段就是一条已启用纠错触发词时，替换后直接上屏。热词只在整段一至四字且完全一致时直接上屏；更长的热词和句子里夹着的词仍润色。纠错不参与键盘选词或词频学习。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索词条或纠错规则", text: $search)
                    .textFieldStyle(.plain)
                    .submitScope()
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("清除搜索")
                }
            }
            .padding(9)
            .background(style.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.cardBorder))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hotwordFields.padding(16)
                        .background(style.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.cardBorder))
                    replacementFields.padding(16)
                        .background(style.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.cardBorder))
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(style.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("应用后请保存设置。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    if hasChanges { confirmingDiscard = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                // No default action: Return belongs to the focused input, never the sheet.
                Button("应用", action: apply).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 740, maxWidth: 1000,
               minHeight: 440, idealHeight: 620, maxHeight: 800)
        .background(style.canvas)
        .tint(style.accent)
        .interactiveDismissDisabled()
        .confirmationDialog("放弃尚未应用的语音词典更改？", isPresented: $confirmingDiscard) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .accessibilityIdentifier("voice-vocabulary-editor")
    }

    private var hotwordFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别词条").font(.headline)
            VocabularyReturnField(text: $newWord, placeholder: "添加姓名、术语或专有名词，回车添加", onReturn: addWord)
                .frame(height: 26)
                .accessibilityIdentifier("voice-vocabulary-new-word")
            Text("Whisper、macOS 与支持热词的云端服务使用这些词条，标准和聊天润色也会参考写法；Cohere 和 Interfaze 暂不使用。最多 500 个；纠错规则对各识别方式均生效，在润色前替换一次。")
                .font(.caption).foregroundStyle(.secondary)
            if editingWordIndex != nil {
                HStack {
                    VocabularyReturnField(text: $editingWord, placeholder: "编辑词条", onReturn: saveWord)
                        .frame(height: 26)
                    Button("完成", action: saveWord)
                    Button("取消") { editingWordIndex = nil; editingWord = ""; errorMessage = nil }
                }
            }
            let indices = draft.value.hotwords.indices.filter { matches(draft.value.hotwords[$0]) }
            if indices.isEmpty {
                emptyLabel(draft.value.hotwords.isEmpty ? "还没有词条，在上方输入并回车添加。" : "没有匹配的词条")
            }
            VocabularyFlowLayout(spacing: 8) {
                ForEach(indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Text(draft.value.hotwords[index]).lineLimit(1)
                            .help(draft.value.hotwords[index])
                        Menu {
                            Button("编辑") {
                                editingWordIndex = index
                                editingWord = draft.value.hotwords[index]
                                errorMessage = nil
                            }
                            Button("删除", role: .destructive) {
                                do { try draft.removeWord(at: index) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(editingWordIndex != nil)
                        .accessibilityLabel("词条 \(draft.value.hotwords[index]) 的操作")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(style.canvas, in: Capsule())
                    .overlay(Capsule().stroke(style.cardBorder))
                }
            }
        }
    }

    private var replacementFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("纠错规则").font(.headline)
                Spacer()
                Button {
                    editingRule = VoiceReplacement()
                    triggerText = ""
                    errorMessage = nil
                } label: { Label("新增规则", systemImage: "plus") }
                .disabled(editingRule != nil || draft.value.replacements.count >= 200)
            }
            Text("在润色等文字整理之前替换一次，润色看到的是替换后的文字；仅转写也生效 · 最多 200 条")
                .font(.caption).foregroundStyle(.secondary)
            if let rule = editingRule {
                VoiceReplacementEditor(
                    rule: Binding(get: { editingRule ?? rule }, set: { editingRule = $0 }),
                    triggerText: $triggerText,
                    errorMessage: $errorMessage,
                    save: saveRule,
                    cancel: { editingRule = nil; triggerText = ""; errorMessage = nil }
                )
            }
            let rules = draft.value.replacements.filter {
                matches($0.target) || $0.sources.contains(where: matches)
            }
            if rules.isEmpty && editingRule == nil {
                emptyLabel(draft.value.replacements.isEmpty ? "还没有纠错规则" : "没有匹配的规则")
            }
            VocabularyFlowLayout(spacing: 8) {
                ForEach(rules) { rule in
                    HStack(spacing: 8) {
                        Text(rule.sources.joined(separator: "、"))
                            .lineLimit(2).help(rule.sources.joined(separator: "、"))
                        Image(systemName: "arrow.right")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("替换为")
                        Text(rule.target).lineLimit(2).help(rule.target)
                        if !rule.isEnabled {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.secondary)
                                .help("已停用").accessibilityLabel("已停用")
                        }
                        Menu {
                            Button("编辑") {
                                editingRule = rule
                                triggerText = ""
                                errorMessage = nil
                            }
                            Button("删除", role: .destructive) {
                                draft.removeRule(id: rule.id)
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(editingRule != nil)
                        .accessibilityLabel("纠错规则的操作")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: 320, alignment: .leading)
                    .background(style.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.cardBorder))
                }
            }
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    private func matches(_ value: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }

    private func addWord() {
        guard !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try draft.addWord(newWord)
            newWord = ""
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveWord() {
        guard let index = editingWordIndex else { return }
        do {
            try draft.updateWord(at: index, to: editingWord)
            editingWordIndex = nil
            editingWord = ""
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func commitRule(to value: inout VoiceVocabularyDraft) throws {
        guard let rule = editingRule else { return }
        try value.saveRule(rule, pendingTrigger: triggerText)
    }

    private func saveRule() {
        do {
            var value = draft
            try commitRule(to: &value)
            draft = value
            editingRule = nil
            triggerText = ""
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply() {
        do {
            // Stage all pending edits together. Validation failure leaves the editor intact.
            var value = draft
            if let index = editingWordIndex {
                try value.updateWord(at: index, to: editingWord)
            }
            if !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try value.addWord(newWord)
            }
            try commitRule(to: &value)
            vocabulary = try value.validatedValue()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

}

private func triggerKey(_ text: String) -> String {
    VoiceVocabularyDraft.triggerKey(text)
}

/// Packs natural-width chips and cards into rows without a fixed column count.
private struct VocabularyFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, item) in layout.items.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        var items: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let itemWidth = min(ideal.width, width ?? ideal.width)
            let measured = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            let size = CGSize(width: itemWidth, height: measured.height)
            if x > 0, let width, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width ?? usedWidth, height: y + rowHeight), items)
    }
}

private struct VoiceReplacementEditor: View {
    @Environment(\.voiceSettingsStyle) private var style
    @Binding var rule: VoiceReplacement
    @Binding var triggerText: String
    @Binding var errorMessage: String?
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    triggerFields.frame(minWidth: 230, maxWidth: .infinity)
                    replacementField.frame(minWidth: 210, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 12) {
                    triggerFields
                    replacementField
                }
            }
            HStack {
                if !rule.isEnabled {
                    Text("已停用，编辑后保留停用状态")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消编辑", action: cancel)
                Button("完成", action: save)
            }
        }
        .padding(12)
        .background(style.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private var triggerFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("匹配文字").font(.subheadline.bold())
                Spacer()
                Text("\(rule.sources.count)/\(VoiceReplacement.maximumSources)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !rule.sources.isEmpty {
                VocabularyFlowLayout(spacing: 6) {
                    ForEach(Array(rule.sources.enumerated()), id: \.offset) { index, source in
                        HStack(spacing: 4) {
                            Text(source).lineLimit(1).help(source)
                            Button { rule.sources.remove(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("删除触发词 \(source)")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
            VocabularyReturnField(text: $triggerText, placeholder: "输入触发词，回车添加（最多5个）", onReturn: addTrigger)
                .frame(height: 26)
        }
    }

    private var replacementField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("替换为").font(.subheadline.bold())
            TextEditor(text: $rule.target)
                .font(.body).padding(5).frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("替换文字，可填写多行片段")
        }
    }

    private func addTrigger() {
        let source = triggerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        guard rule.sources.count < VoiceReplacement.maximumSources else {
            errorMessage = "每条规则最多 5 个触发词"; return
        }
        guard source.count <= 80, !source.contains(where: \.isNewline) else {
            errorMessage = "触发词需为单行，最多 80 个字符"; return
        }
        guard !rule.sources.contains(where: { triggerKey($0) == triggerKey(source) }) else {
            errorMessage = "触发词重复（忽略大小写和空白）"; return
        }
        rule.sources.append(source)
        triggerText = ""
        errorMessage = nil
    }
}

/// Consume Return at the field editor so a sheet's button cannot also receive it.
/// The NSTextField remains first responder after its contents are cleared.
private struct VocabularyReturnField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .default
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text,
           (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: VocabularyReturnField
        init(_ parent: VocabularyReturnField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  !textView.hasMarkedText() else { return false }
            parent.onReturn()
            return true
        }
    }
}

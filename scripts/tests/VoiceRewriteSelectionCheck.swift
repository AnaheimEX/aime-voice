import AIMEVoiceHost
import Foundation
import InputMethodKit

// External IMK transport boundary. A generated string cannot prove client identity.
final class Document {
    var text = "前文"
    var selection = NSRange(location: 2, length: 0)
}
final class Client: NSObject, IMKTextInput {
    let document: Document
    var identity: String
    var generatesIdentifier = false
    var application = "app.test.editor"
    var currentSelectionOnly = false
    var ignoreInsert = false
    var onInsert: ((String) -> Void)?
    var insertCount = 0
    var unreadable = false
    var marked = NSRange(location: NSNotFound, length: 0)
    init(_ document: Document, id: String = "field-a") { self.document = document; identity = id }
    func insertText(_ value: Any!, replacementRange: NSRange) {
        if ignoreInsert { return }
        insertCount += 1
        if let onInsert { onInsert(value as! String); return }
        let range = currentSelectionOnly || replacementRange.location == NSNotFound ? document.selection : replacementRange
        let text = value as! String
        document.text = (document.text as NSString).replacingCharacters(in: range, with: text)
        document.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
    }
    func selectedRange() -> NSRange { document.selection }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard !unreadable, range.location != NSNotFound, NSMaxRange(range) <= (document.text as NSString).length else { return nil }
        return NSAttributedString(string: (document.text as NSString).substring(with: range))
    }
    func uniqueClientIdentifierString() -> String! { generatesIdentifier ? UUID().uuidString : identity }
    func bundleIdentifier() -> String! { application }
    func setMarkedText(_ value: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
    func markedRange() -> NSRange { marked }
    func length() -> Int { (document.text as NSString).length }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name: String!) {}
    func selectMode(_ identifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

// Stateful external AX boundary: its field identity/coordinates are independent of IMK.
@MainActor final class Accessibility: VoiceRewriteAccessibility {
    var isTrusted = true
    var element = NSObject()
    var pid: Int32 = 42
    var bundle = "app.test.editor"
    var value = "前文"
    var selection: NSRange? = NSRange(location: 2, length: 0)
    var editable = true
    var secure = false
    var selectedWritable = true
    var valueWritable = false
    var singleLine = false
    var noOp = false
    var delaySelection = false
    var delayWrite = false
    var pending: (() -> Void)?
    var onSelect: (() -> Void)?
    var writeCount = 0
    func focusedField() -> VoiceRewriteFieldSnapshot? {
        guard isTrusted else { return nil }
        return VoiceRewriteFieldSnapshot(element: element, processID: pid, bundleID: bundle,
            value: value, selection: selection, isEditable: editable, isSecure: secure,
            selectedTextSettable: selectedWritable, valueSettable: valueWritable, singleLine: singleLine)
    }
    func select(_ range: NSRange, in field: VoiceRewriteFieldSnapshot) -> Bool {
        onSelect?()
        if delaySelection { pending = { self.selection = range } }
        else { selection = range }
        return true
    }
    func replaceSelectedText(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool {
        writeCount += 1
        guard !noOp, let selection else { return true }
        let next = (value as NSString).replacingCharacters(in: selection, with: text)
        if delayWrite { pending = { self.value = next } } else { value = next }
        return true
    }
    func replaceValue(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool {
        writeCount += 1
        if !noOp { value = text }
        return true
    }
    func waitForUpdate() async {
        let update = pending; pending = nil; update?()
        await Task.yield()
    }
}

@main struct VoiceRewriteSelectionCheck {
    @MainActor static func main() async {
        var cases = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); cases += 1
        }
        func setup(_ text: String = "使用智借输入") async -> (Accessibility, Client, VoiceDictationOrigin) {
            let ax = Accessibility()
            let client = Client(Document())
            // IMK remains stale at "前文" and offset 2; AX knows the actual document.
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            ax.pending = { ax.value = "前文" + text; ax.selection = NSRange(location: ax.value.utf16.count, length: 0) }
            let origin = await anchor.resolve(sessionID: UUID(), transcript: "嗯" + text,
                                              committed: text, client: client)
            precondition(origin != nil, "delayed AX insertion must establish provenance despite stale IMK")
            return (ax, client, origin!)
        }
        do {
            let (ax, _, origin) = await setup()
            let proxy = Client(Document(), id: "new-proxy")
            ax.selection = NSRange(location: 0, length: 0)
            let target = VoiceRewriteSelection(client: proxy, origin: origin)!
            check(target.text == "使用智借输入" && origin.owns(target, client: proxy), "proxy and cursor changes preserve AX target")
            ax.delaySelection = true; ax.delayWrite = true
            let prepared = await target.prepare(in: proxy)
            check(prepared && ax.selection == target.range && ax.writeCount == 0, "rewrite selects recent dictation before recording without changing text")
            let result = await target.insert("使用智界输入", into: proxy)
            check(result == nil && ax.value == "前文使用智界输入", "delayed selection and write succeed without IMK coordinates")
            let updated = origin.advanced(target: target, replacement: "使用智界输入", client: proxy)!
            check(updated.sessionID == origin.sessionID && updated.transcript == origin.transcript, "continuous rewrite preserves ASR/session")
            ax.selection = NSRange(location: 0, length: 0)
            let second = VoiceRewriteSelection(client: proxy, origin: updated)!
            let secondResult = await second.insert("请使用智界输入", into: proxy)
            check(secondResult == nil && ax.value == "前文请使用智界输入", "second rewrite uses latest verified text")
            let repeated = await second.insert("重复写入", into: proxy)
            check(repeated != nil && ax.writeCount == 2, "same target cannot write twice")
        }
        do {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            ax.element = NSObject()
            let result = await target.insert("错误窗口", into: client)
            check(result != nil && ax.writeCount == 0, "other field never receives rewrite")
            check(VoiceRewriteSelection(client: client, origin: origin) == nil, "other field cannot resolve old origin")
        }
        do {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            ax.value = "前文手工编辑"
            let result = await target.insert("使用智界输入", into: client)
            check(result != nil && ax.value == "前文手工编辑" && ax.writeCount == 0, "manual edit invalidates whole snapshot")
        }
        do {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            ax.noOp = true; ax.valueWritable = true
            let result = await target.insert("使用智界输入", into: client)
            check(result != nil && ax.value == "前文使用智借输入" && ax.writeCount == 1, "AX no-op never retries another write strategy")
            check(origin.advanced(target: target, replacement: "使用智界输入", client: client) == nil, "no-op cannot advance recent dictation")
        }
        do {
            let (ax, client, origin) = await setup()
            ax.noOp = true
            // IMK and AX use different offsets but both expose the same selected text.
            client.document.text = origin.rendered
            client.document.selection = NSRange(location: 0, length: origin.rendered.utf16.count)
            client.onInsert = { replacement in
                ax.value = "前文" + replacement
                ax.selection = NSRange(location: ax.value.utf16.count, length: 0)
            }
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            let result = await target.insert("使用智界输入", into: client)
            check(result == nil && client.insertCount == 1 && ax.value == "前文使用智界输入",
                  "verified native selection handles Electron AX no-op without absolute range")
            check(origin.advanced(target: target, replacement: "使用智界输入", client: client) != nil,
                  "native replacement still requires full-field readback to advance recent dictation")
        }
        do {
            let (ax, client, origin) = await setup()
            ax.selectedWritable = false; ax.valueWritable = true
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            let result = await target.insert("使用智界输入", into: client)
            check(result == nil && ax.value == "前文使用智界输入", "bounded AXValue preserves unselected text")
        }
        do {
            let (ax, client, origin) = await setup()
            ax.selection = NSRange(location: 4, length: 2)
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            check(target.text == "智借" && !target.isRecentDictation, "explicit AX selection takes priority")
            let result = await target.insert("智界", into: client)
            let advanced = origin.advanced(target: target, replacement: "智界", client: client)
            check(result == nil && advanced?.rendered == "使用智界输入", "partial rewrite advances full origin")
            let adopted = target.committedOrigin(sessionID: UUID(), transcript: "")
            check(adopted?.rendered == "智界" && adopted?.range == NSRange(location: 4, length: 2), "explicit rewrite can establish verified target")
        }
        do {
            let (ax, client, origin) = await setup()
            ax.selection = NSRange(location: 4, length: 2)
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            ax.selection = NSRange(location: 3, length: 2)
            let result = await target.insert("智界", into: client)
            check(result == .selectionChanged && ax.writeCount == 0, "explicit selection change aborts")
        }
        do {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            ax.onSelect = { ax.value = "变化使用智借输入" }
            let result = await target.insert("使用智界输入", into: client)
            check(result != nil && ax.writeCount == 0, "edit during selection aborts before writing")
        }
        do {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            let result = await target.insert("使用智借输入", into: client)
            check(result == nil && ax.writeCount == 0, "unchanged rewrite is verified no-op")
            check(origin.advanced(target: target, replacement: "使用智借输入", client: client) != nil, "unchanged text keeps valid origin")
        }
        do {
            let ax = Accessibility(); let client = Client(Document())
            ax.value = "哈哈"; ax.selection = nil
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            ax.value = "哈哈哈"
            let origin = await anchor.resolve(sessionID: UUID(), transcript: "哈", committed: "哈", client: client)
            check(origin == nil, "ambiguous repeated fragment is rejected without AX position evidence")
        }
        do {
            let ax = Accessibility(); let client = Client(Document())
            ax.value = "哈哈"; ax.selection = NSRange(location: 1, length: 0)
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            ax.value = "哈哈哈"
            let origin = await anchor.resolve(sessionID: UUID(), transcript: "哈", committed: "哈", client: client)
            check(origin?.range == NSRange(location: 1, length: 1), "verified AX edit disambiguates repeated fragment")
        }
        do {
            let ax = Accessibility(); let client = Client(Document())
            ax.value = "🙂前文"; ax.selection = NSRange(location: 4, length: 0)
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            ax.value = "🙂前文智借🙂"; ax.selection = NSRange(location: 8, length: 0)
            let origin = await anchor.resolve(sessionID: UUID(), transcript: "智借🙂", committed: "智借🙂", client: client)
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            let result = await target.insert("智界输入🙂", into: client)
            let advanced = origin?.advanced(target: target, replacement: "智界输入🙂", client: client)
            check(result == nil && advanced?.range == NSRange(location: 4, length: 6), "UTF16 ranges preserve emoji")
        }
        do {
            let (ax, client, origin) = await setup()
            ax.isTrusted = false
            let message = VoiceRewriteSelection.preparationFailureMessage(client: client, origin: origin)
            check(message.contains("艾么语音测试") && message.contains("辅助功能"), "actual permission denial identified accurately")
            ax.isTrusted = true; ax.value = "用户编辑"
            let changed = VoiceRewriteSelection.preparationFailureMessage(client: client, origin: origin)
            check(!changed.contains("辅助功能"), "field mismatch is not reported as permission denial")
        }
        for mutation in 0..<5 {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            switch mutation {
            case 0: ax.secure = true
            case 1: ax.editable = false
            case 2: ax.pid = 99
            case 3: ax.bundle = "another.app"
            default: ax.isTrusted = false
            }
            let result = await target.insert("不应上屏", into: client)
            check(result != nil && ax.writeCount == 0, "secure/read-only/process/app/permission changes reject writes")
        }
        do {
            let ax = Accessibility(); let client = Client(Document())
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            let origin = await anchor.resolve(sessionID: UUID(), transcript: "未上屏", committed: "未上屏", client: client)
            check(origin == nil, "no observed insertion cannot establish origin")
        }
        do {
            let (ax, client, origin) = await setup()
            client.document.text = "用户选区"; client.document.selection = NSRange(location: 0, length: 2)
            ax.secure = true
            check(VoiceRewriteSelection(client: client, origin: origin) == nil,
                  "known secure AX field cannot fall back to IMK selected text")
        }
        do {
            let ax = Accessibility(); let client = Client(Document())
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            ax.pending = { ax.value = "前文刚才听写"; ax.selection = NSRange(location: 6, length: 0) }
            let store = VoiceRecentDictation()
            let session = UUID()
            store.track(anchor: anchor, sessionID: session, transcript: "刚才听写", committed: "刚才听写", client: client)
            let latest = await store.latest()
            check(latest?.rendered == "刚才听写" && latest?.sessionID == session,
                  "immediate rewrite awaits pending insertion readback")
        }
        do {
            let (_, _, current) = await setup("最新听写")
            let ax = Accessibility(); let client = Client(Document())
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            let store = VoiceRecentDictation()
            store.track(anchor: anchor, sessionID: UUID(), transcript: "过期听写", committed: "过期听写", client: client)
            let oldRead = Task { @MainActor in await store.latest() }
            await Task.yield()
            store.replace(current)
            _ = await oldRead.value
            let latest = await store.latest()
            check(latest?.sessionID == current.sessionID && latest?.rendered == "最新听写",
                  "late readback cannot overwrite replacement generation")
        }
        do {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            let result = await target.insert(" ", into: client)
            check(result == .emptyResult && ax.writeCount == 0, "empty rewrite cannot remove input")
        }
        do {
            let (ax, client, origin) = await setup()
            ax.singleLine = true
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            let result = await target.insert("第一行\n第二行", into: client)
            check(result != nil && ax.writeCount == 0, "single-line field rejects multiline edit")
        }
        do {
            let ax = Accessibility(); let client = Client(Document())
            ax.value = "前文后文"; ax.selection = nil
            let anchor = VoiceDictationAnchor.capture(client: client, accessibility: ax)!
            ax.value = "前文智界后文"
            let origin = await anchor.resolve(sessionID: UUID(), transcript: "智界", committed: "智界", client: client)
            check(origin?.range == NSRange(location: 2, length: 2), "unique before/after change resolves missing selection")
        }
        do {
            let (ax, client, origin) = await setup()
            let target = VoiceRewriteSelection(client: client, origin: origin)!
            ax.selectedWritable = false; ax.valueWritable = false
            let result = await target.insert("不应上屏", into: client)
            check(result != nil && ax.writeCount == 0, "unsupported field never falls back to append")
        }
        print("PASS \(cases) AX rewrite target scenarios")
    }
}

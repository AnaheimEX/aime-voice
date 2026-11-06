import AIMEVoice
import AIMEVoiceHost
import Foundation
import InputMethodKit

/// Stand-in for the focused AX field. Identity is one stable `element` object per field.
@MainActor final class FakeRewriteAccessibility: VoiceRewriteAccessibility {
    final class Element {}

    var isTrusted = true
    var value: String
    var selection: NSRange?
    var bundleID: String
    var processID: Int32 = 4242
    var isEditable = true
    var isSecure = false
    var selectedTextSettable = true
    var valueSettable = false
    var singleLine = false
    var hasFocusedField = true
    /// Operations report success but leave the field untouched.
    var selectIsEffective = true
    /// `select` reports failure and changes nothing.
    var selectSucceeds = true
    var replaceSelectedTextIsEffective = true
    var replaceValueIsEffective = true
    /// Number of `focusedField()` reads that still return the pre-write state after a write.
    var pollsBeforeUpdate = 0
    private(set) var element = Element()
    private(set) var readCount = 0
    private(set) var selectCalls: [NSRange] = []
    private(set) var replaceSelectedTextCalls: [String] = []
    private(set) var replaceValueCalls: [String] = []
    private(set) var waitCount = 0

    private var published: (value: String, selection: NSRange?)
    private var pendingReads = 0

    init(value: String, selection: NSRange? = nil, bundleID: String = "com.example.editor") {
        self.value = value; self.selection = selection; self.bundleID = bundleID
        published = (value, selection)
    }

    /// Focus moves to a different field: same app, new element identity.
    func focusNewField(value: String, selection: NSRange? = nil) {
        element = Element()
        self.value = value; self.selection = selection
        published = (value, selection); pendingReads = 0
    }

    /// The user types: state changes immediately and is visible to the next read.
    func userEdits(_ value: String, selection: NSRange? = nil) {
        self.value = value; self.selection = selection
        published = (value, selection); pendingReads = 0
    }

    func focusedField() -> VoiceRewriteFieldSnapshot? {
        readCount += 1
        guard hasFocusedField else { return nil }
        if pendingReads > 0 { pendingReads -= 1 } else { published = (value, selection) }
        return VoiceRewriteFieldSnapshot(
            element: element, processID: processID, bundleID: bundleID, value: published.value,
            selection: published.selection, isEditable: isEditable, isSecure: isSecure,
            selectedTextSettable: selectedTextSettable, valueSettable: valueSettable, singleLine: singleLine)
    }

    func select(_ range: NSRange, in field: VoiceRewriteFieldSnapshot) -> Bool {
        selectCalls.append(range)
        guard selectSucceeds else { return false }
        guard isTrusted, field.value == value, NSMaxRange(range) <= (value as NSString).length else { return false }
        if selectIsEffective { selection = range; pendingReads = pollsBeforeUpdate }
        return true
    }

    func replaceSelectedText(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool {
        replaceSelectedTextCalls.append(text)
        guard isTrusted, selectedTextSettable, let selection, field.selection == selection else { return false }
        if replaceSelectedTextIsEffective {
            value = (value as NSString).replacingCharacters(in: selection, with: text)
            self.selection = NSRange(location: selection.location + (text as NSString).length, length: 0)
            pendingReads = pollsBeforeUpdate
        }
        return true
    }

    func replaceValue(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool {
        replaceValueCalls.append(text)
        guard isTrusted, valueSettable else { return false }
        if replaceValueIsEffective { value = text; selection = nil; pendingReads = pollsBeforeUpdate }
        return true
    }

    /// No real sleeping in tests.
    func waitForUpdate() async { waitCount += 1 }
}

/// Minimal IMKTextInput so VoiceRewriteSelection / VoiceDictationAnchor can be built in tests.
final class FakeTextInput: NSObject, IMKTextInput {
    var bundle: String
    var marked = NSRange(location: NSNotFound, length: 0)
    var selected = NSRange(location: NSNotFound, length: 0)
    init(bundle: String = "com.example.editor") { self.bundle = bundle }

    func bundleIdentifier() -> String! { bundle }
    func markedRange() -> NSRange { marked }
    func selectedRange() -> NSRange { selected }
    func insertText(_ string: Any!, replacementRange: NSRange) {}
    func insertText(_ string: Any!) {}
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    func length() -> Int { 0 }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func supportsProperty(_ property: UInt32) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "fake" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
    func windowLevel() -> CGWindowLevel { 0 }
    func validAttributesForMarkedText() -> [Any]! { [] }
}

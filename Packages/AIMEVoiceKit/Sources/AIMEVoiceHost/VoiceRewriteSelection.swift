import AIMEVoice
// Based on Type4Me ReviseAccessibilityClient / TrackedTextReplacementEngine (MIT).
// https://github.com/joewongjc/type4me ; see licenses/type4me.LICENSE.txt.
import Foundation
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import os
public import InputMethodKit

private func validVoiceRange(_ range: NSRange, in text: String) -> Bool {
    range.location >= 0 && range.location != NSNotFound && range.length >= 0
        && range.location <= text.utf16.count && range.length <= text.utf16.count - range.location
}

/// A read of one focused AX field. Coordinates are AX UTF-16, never IMK coordinates.
@MainActor public struct VoiceRewriteFieldSnapshot {
    public let element: AnyObject
    public let processID: Int32
    public let bundleID: String
    public let value: String
    public let selection: NSRange?
    public let isEditable: Bool
    public let isSecure: Bool
    public let selectedTextSettable: Bool
    public let valueSettable: Bool
    public let singleLine: Bool

    public init(element: AnyObject, processID: Int32, bundleID: String, value: String,
                selection: NSRange?, isEditable: Bool = true, isSecure: Bool = false,
                selectedTextSettable: Bool = true, valueSettable: Bool = false,
                singleLine: Bool = false) {
        self.element = element; self.processID = processID; self.bundleID = bundleID
        self.value = value; self.selection = selection; self.isEditable = isEditable
        self.isSecure = isSecure; self.selectedTextSettable = selectedTextSettable
        self.valueSettable = valueSettable; self.singleLine = singleLine
    }

    fileprivate func sameField(as other: Self) -> Bool {
        processID == other.processID && bundleID == other.bundleID && CFEqual(element, other.element)
    }
    fileprivate var usable: Bool { isEditable && !isSecure && value.utf16.count <= 100_000 }
}

/// External system boundary. Implementations must never prompt for permission or
/// send global paste/delete events. A successful setter still requires readback.
@MainActor public protocol VoiceRewriteAccessibility: AnyObject {
    var isTrusted: Bool { get }
    func focusedField() -> VoiceRewriteFieldSnapshot?
    /// The field that should receive `client`'s text, or nil when no focused field belongs to it.
    /// Refine this to make diagnosis distinguish "no field at all" from "field belongs to another app".
    func focusedField(matching client: (any IMKTextInput)?) -> VoiceRewriteFieldSnapshot?
    func select(_ range: NSRange, in field: VoiceRewriteFieldSnapshot) -> Bool
    func replaceSelectedText(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool
    func replaceValue(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool
    func waitForUpdate() async
}

extension VoiceRewriteAccessibility {
    public func waitForUpdate() async { try? await Task.sleep(for: .milliseconds(40)) }
    /// Default: the frontmost field is the field, no matter which client asked.
    public func focusedField(matching client: (any IMKTextInput)?) -> VoiceRewriteFieldSnapshot? {
        focusedField()
    }
}

/// Captured after recording starts, before the host inserts its dictation result.
/// No IMK proxy or controller is retained. The owner controls TTL and replacement.
@MainActor public final class VoiceDictationAnchor {
    private let before: VoiceRewriteFieldSnapshot
    private let accessibility: any VoiceRewriteAccessibility
    private init(before: VoiceRewriteFieldSnapshot, accessibility: any VoiceRewriteAccessibility) {
        self.before = before; self.accessibility = accessibility
    }

    public static func capture(client: any IMKTextInput,
                               accessibility: (any VoiceRewriteAccessibility)? = nil) -> VoiceDictationAnchor? {
        let adapter = accessibility ?? VoiceSystemRewriteAccessibility.shared
        guard adapter.isTrusted, let field = adapter.focusedField(), field.usable,
              field.bundleID == client.bundleIdentifier() else { return nil }
        return VoiceDictationAnchor(before: field, accessibility: adapter)
    }

    public func resolve(sessionID: UUID, transcript: String, committed: String,
                        client: any IMKTextInput) async -> VoiceDictationOrigin? {
        guard !committed.isEmpty, committed.count <= 2000 else { return nil }
        for attempt in 0..<9 {
            guard !Task.isCancelled, accessibility.isTrusted,
                  let after = accessibility.focusedField(), after.usable,
                  after.sameField(as: before), after.bundleID == client.bundleIdentifier() else { return nil }
            if after.value != before.value {
                guard let range = Self.insertedRange(before: before, after: after.value, text: committed) else { return nil }
                return VoiceDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: committed,
                                            range: range, field: after, accessibility: accessibility)
            }
            if attempt < 8 { await accessibility.waitForUpdate() }
        }
        return nil
    }

    private static func insertedRange(before: VoiceRewriteFieldSnapshot, after: String, text: String) -> NSRange? {
        let old = before.value as NSString
        let new = after as NSString
        if let selection = before.selection, validVoiceRange(selection, in: before.value),
           old.replacingCharacters(in: selection, with: text) == after {
            return NSRange(location: selection.location, length: text.utf16.count)
        }
        // Locate by an exact before/after edit, not a fuzzy substring search. Two
        // indistinguishable placements are ambiguous and must not become a target.
        let removed = old.length + text.utf16.count - new.length
        guard removed >= 0 else { return nil }
        var search = NSRange(location: 0, length: new.length)
        var match: NSRange?
        while search.length >= text.utf16.count {
            let candidate = new.range(of: text, options: [], range: search)
            if candidate.location == NSNotFound { break }
            let previous = NSRange(location: candidate.location, length: removed)
            if validVoiceRange(previous, in: before.value),
               old.replacingCharacters(in: previous, with: text) == after {
                guard match == nil else { return nil }
                match = candidate
            }
            let next = candidate.location + 1
            search = NSRange(location: next, length: new.length - next)
        }
        return match
    }
}

/// Explicit AX selection or unchanged most recent dictation, with verified writes.
@MainActor public final class VoiceRewriteSelection {
    public let text: String
    public let range: NSRange
    public let isRecentDictation: Bool
    public private(set) var preparationFailureMessage: String?
    fileprivate let field: VoiceRewriteFieldSnapshot?
    fileprivate let accessibility: any VoiceRewriteAccessibility
    fileprivate var insertedText: String?
    fileprivate var verifiedAfter: VoiceRewriteFieldSnapshot?
    private var attempted = false
    private var observedUnchanged = false
    private var caretRestored = false
    private let explicitSelection: NSRange?

    public init?(client: any IMKTextInput, origin: VoiceDictationOrigin? = nil,
                 accessibility: (any VoiceRewriteAccessibility)? = nil) {
        guard !SecureEventInputShield.isSecureEventInput(), client.markedRange().location == NSNotFound else { return nil }
        let adapter = accessibility ?? origin?.accessibility ?? VoiceSystemRewriteAccessibility.shared
        self.accessibility = adapter
        if adapter.isTrusted, let field = adapter.focusedField(), field.usable,
           field.bundleID == client.bundleIdentifier() {
            let range: NSRange
            if let selected = field.selection, selected.length > 0, validVoiceRange(selected, in: field.value) {
                range = selected; isRecentDictation = false; explicitSelection = selected
            } else {
                guard let origin, origin.matches(field), validVoiceRange(origin.range, in: field.value) else { return nil }
                range = origin.range; isRecentDictation = true; explicitSelection = nil
            }
            let text = (field.value as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 else { return nil }
            self.text = text; self.range = range; self.field = field
        } else { return nil }
    }

    /// Select the tracked span before listening so the user can see the edit target.
    public func prepare(in client: any IMKTextInput) async -> Bool {
        guard let field, let current = currentField(client: client, expectedValue: field.value),
              client.markedRange().location == NSNotFound else { return false }
        if let explicitSelection { return current.selection == explicitSelection }
        guard accessibility.select(range, in: current) else { return false }
        for attempt in 0..<9 {
            guard !Task.isCancelled, let selected = currentField(client: client, expectedValue: field.value) else { return false }
            if selected.selection == range { return true }
            if attempt < 8 { await accessibility.waitForUpdate() }
        }
        return false
    }

    /// nil means the entire AX field was verified after the single write attempt.
    public var isSingleLine: Bool { field?.singleLine ?? false }

    public func insert(_ replacement: String, into client: any IMKTextInput, allowEmpty: Bool = false) async -> VoiceCommitTarget.Rejection? {
        guard !attempted else { return .selectionChanged }
        // Only the validated rewrite completion path opts into explicit deletion.
        guard allowEmpty || !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyResult }
        guard client.markedRange().location == NSNotFound else { return .selectionChanged }
        attempted = true // One transaction; never replay a completed or partial edit.
        guard let field, let current = currentField(client: client, expectedValue: field.value) else {
            preparationFailureMessage = Self.preparationFailureMessage(client: client, origin: nil, accessibility: accessibility)
            return .contextChanged
        }
        if let explicitSelection, current.selection != explicitSelection { return .selectionChanged }
        guard !field.singleLine || (!replacement.contains("\n") && !replacement.contains("\r")) else { return .contextChanged }
        let expected = (field.value as NSString).replacingCharacters(in: range, with: replacement)
        if expected == field.value {
            insertedText = replacement; verifiedAfter = current
            return nil
        }
        if current.selectedTextSettable {
            guard accessibility.select(range, in: current) else { return .selectionChanged }
            var selectionReady = false
            for attempt in 0..<9 {
                guard !Task.isCancelled, let selected = currentField(client: client, expectedValue: field.value) else { return .contextChanged }
                if selected.selection == range { selectionReady = true; break }
                if attempt < 8 { await accessibility.waitForUpdate() }
            }
            guard selectionReady, let selected = currentField(client: client, expectedValue: field.value),
                  selected.selection == range else {
                preparationFailureMessage = "输入框未确认原文选区，未写入"
                return .selectionChanged
            }
            // An AX setter can report failure after issuing an edit. Do not retry
            // with AXValue/paste: observe this one attempt, then fail closed.
            _ = accessibility.replaceSelectedText(replacement, in: selected)
        } else if current.valueSettable {
            guard let unchanged = currentField(client: client, expectedValue: field.value) else { return .contextChanged }
            _ = accessibility.replaceValue(expected, in: unchanged)
        } else {
            preparationFailureMessage = "当前输入框不支持安全替换，未写入"
            return .selectionChanged
        }
        // Type4Me checks full-field readback because Electron may silently ignore
        // AXSelectedText. Reuse IMK insertion only when its own selection also
        // proves the exact old text; never infer coordinates across AX and IMK.
        let first = await observe(expected: expected, replacement: replacement, client: client)
        guard first != nil else { return nil }
        guard observedUnchanged, current.selectedTextSettable,
              let unchanged = currentField(client: client, expectedValue: field.value),
              unchanged.selection == range else { return first }
        for attempt in 0..<9 {
            guard let selected = currentField(client: client, expectedValue: field.value),
                  selected.selection == range, client.markedRange().location == NSNotFound else { return .contextChanged }
            let nativeRange = client.selectedRange()
            if nativeRange.location != NSNotFound, nativeRange.length > 0,
               client.attributedSubstring(from: nativeRange)?.string == text {
                client.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
                return await observe(expected: expected, replacement: replacement, client: client)
            }
            if attempt < 8 { await accessibility.waitForUpdate() }
        }
        preparationFailureMessage = "输入框未确认改写选区，未重复写入"
        return first
    }

    private func observe(expected: String, replacement: String, client: any IMKTextInput) async -> VoiceCommitTarget.Rejection? {
        observedUnchanged = false
        guard let field else { return .contextChanged }
        for attempt in 0..<9 {
            guard !Task.isCancelled, accessibility.isTrusted,
                  let observed = accessibility.focusedField(), observed.usable,
                  observed.sameField(as: field), observed.bundleID == client.bundleIdentifier() else { return .clientChanged }
            if observed.value == expected {
                insertedText = replacement; verifiedAfter = observed
                return nil
            }
            if observed.value != field.value { return .contextChanged }
            if attempt < 8 { await accessibility.waitForUpdate() }
        }
        observedUnchanged = true
        preparationFailureMessage = "输入框未确认改写结果，未重复写入"
        return .contextChanged
    }

    /// Collapse the caret onto the end of a recent-dictation span after the user cancelled
    /// the rewrite, so editing continues where the dictation sits. One shot: the single
    /// allowed restore is spent by a success or a failed select, and it never writes text.
    public func restoreCaretIfNeeded(client: (any IMKTextInput)?) -> VoiceRewriteRestoreOutcome {
        if let refused = VoiceRewriteRestoreOutcome.precondition(
            isRecentDictation: isRecentDictation, inserted: insertedText != nil, alreadyRestored: caretRestored) {
            return refused
        }
        guard let client else { return .noClient }
        guard let field, accessibility.isTrusted,
              let current = accessibility.focusedField(matching: client), current.usable,
              current.bundleID == client.bundleIdentifier(), current.sameField(as: field) else { return .fieldChanged }
        guard current.value == field.value else { return .valueChanged }
        guard current.selection == range else { return .selectionChanged }
        caretRestored = true
        let caret = NSRange(location: NSMaxRange(range), length: 0)
        guard accessibility.select(caret, in: current) else { return .selectFailed }
        return .restored
    }

    /// Manual selection can become a new tracked target only after verified AX output.
    public func committedOrigin(sessionID: UUID, transcript: String) -> VoiceDictationOrigin? {
        guard let insertedText, let after = verifiedAfter, accessibility.isTrusted,
              let current = accessibility.focusedField(), current.usable,
              current.sameField(as: after), current.value == after.value else { return nil }
        return VoiceDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: insertedText,
            range: NSRange(location: range.location, length: insertedText.utf16.count),
            field: current, accessibility: accessibility)
    }

    private func currentField(client: any IMKTextInput, expectedValue: String) -> VoiceRewriteFieldSnapshot? {
        guard !Task.isCancelled, accessibility.isTrusted, let field,
              let current = accessibility.focusedField(), current.usable,
              current.sameField(as: field), current.bundleID == client.bundleIdentifier(),
              current.value == expectedValue else { return nil }
        return current
    }

    /// Why a rewrite target cannot be used, mirroring `preparationFailureMessage` branch for branch
    /// so the UI can switch on a reason instead of parsing Chinese text. Nil means the origin span
    /// is verified and the field selection already covers it.
    public enum TargetFailureReason: Equatable, Sendable {
        case untrusted
        case noFocusedField
        case fieldUnusable
        case originMismatch
        case noOrigin
        case selectionInvalid
    }

    public static func targetFailureReason(client: any IMKTextInput, origin: VoiceDictationOrigin?,
                                            accessibility: (any VoiceRewriteAccessibility)? = nil) -> TargetFailureReason? {
        let adapter = accessibility ?? origin?.accessibility ?? VoiceSystemRewriteAccessibility.shared
        guard adapter.isTrusted else { return .untrusted }
        guard let current = adapter.focusedField(matching: client) else { return .noFocusedField }
        guard current.usable else { return .fieldUnusable }
        guard let origin else { return .noOrigin }
        guard origin.matches(current) else { return .originMismatch }
        guard current.selection == origin.range else { return .selectionInvalid }
        return nil
    }

    public static func preparationFailureMessage(client: any IMKTextInput, origin: VoiceDictationOrigin?,
                                                 accessibility: (any VoiceRewriteAccessibility)? = nil) -> String {
        let adapter = accessibility ?? origin?.accessibility ?? VoiceSystemRewriteAccessibility.shared
        switch targetFailureReason(client: client, origin: origin, accessibility: adapter) {
        case .untrusted:
            return "系统当前未授予正在运行的“艾么语音测试”辅助功能权限，请在系统设置核对授权后重新启动输入法"
        case .noFocusedField:
            return "无法读取当前输入框，请重新聚焦后重试或手动选中文字"
        case .fieldUnusable:
            return "当前输入框不可编辑或受保护，未改写"
        case .originMismatch:
            return "输入框或原文已变化，请手动选中文字改写"
        case .noOrigin:
            return "没有已验证的最近听写内容，请先听写或手动选中文字"
        case .selectionInvalid, nil:
            return "无法安全定位原文，请手动选中文字改写"
        }
    }
}

/// Only verified insertion/readback creates provenance. Retain this independently
/// of an IMK controller; repeated revisions preserve original session and ASR text.

/// Outcome of moving the caret back to where a rewrite target sat. Every case but
/// `restored` and `selectFailed` leaves the field untouched.
public enum VoiceRewriteRestoreOutcome: Equatable, Sendable {
    case restored
    case notRecentDictation
    case alreadyInserted
    case alreadyRestored
    case fieldChanged
    case valueChanged
    case selectionChanged
    case noClient
    case selectFailed

    /// Precondition-only view: why a restore is refused before the field is read.
    /// Nil when a restore is still allowed. An inserted edit outranks a spent restore,
    /// and a target that was not a recent dictation is never restored.
    public static func precondition(isRecentDictation: Bool, inserted: Bool, alreadyRestored: Bool)
        -> VoiceRewriteRestoreOutcome? {
        guard isRecentDictation else { return .notRecentDictation }
        if inserted { return .alreadyInserted }
        if alreadyRestored { return .alreadyRestored }
        return nil
    }
}
@MainActor public final class VoiceDictationOrigin {
    public let sessionID: UUID
    public let transcript: String
    public let rendered: String
    public let range: NSRange
    fileprivate let field: VoiceRewriteFieldSnapshot
    fileprivate let accessibility: any VoiceRewriteAccessibility

    fileprivate init(sessionID: UUID, transcript: String, rendered: String, range: NSRange,
                     field: VoiceRewriteFieldSnapshot, accessibility: any VoiceRewriteAccessibility) {
        self.sessionID = sessionID; self.transcript = transcript; self.rendered = rendered
        self.range = range; self.field = field; self.accessibility = accessibility
    }
    fileprivate func matches(_ current: VoiceRewriteFieldSnapshot) -> Bool {
        current.usable && current.sameField(as: field) && current.value == field.value
            && validVoiceRange(range, in: current.value)
            && (current.value as NSString).substring(with: range) == rendered
    }
    public func isCurrent(client: any IMKTextInput) -> Bool {
        guard accessibility.isTrusted, let current = accessibility.focusedField(),
              current.bundleID == client.bundleIdentifier() else { return false }
        return matches(current)
    }
    public func owns(_ selection: VoiceRewriteSelection, client: any IMKTextInput) -> Bool {
        guard isCurrent(client: client), let targetField = selection.field,
              targetField.sameField(as: field), targetField.value == field.value,
              validVoiceRange(selection.range, in: field.value),
              selection.range.location >= range.location, NSMaxRange(selection.range) <= NSMaxRange(range) else { return false }
        return (field.value as NSString).substring(with: selection.range) == selection.text
    }
    public func contains(_ selection: VoiceRewriteSelection, client: any IMKTextInput) -> Bool {
        owns(selection, client: client) && transcript.components(separatedBy: selection.text).count == 2
    }
    public func advanced(target selection: VoiceRewriteSelection, replacement: String,
                         client: any IMKTextInput) -> VoiceDictationOrigin? {
        guard let targetField = selection.field, targetField.sameField(as: field), targetField.value == field.value,
              selection.insertedText == replacement, let after = selection.verifiedAfter,
              validVoiceRange(selection.range, in: field.value),
              selection.range.location >= range.location, NSMaxRange(selection.range) <= NSMaxRange(range),
              accessibility.isTrusted, let current = accessibility.focusedField(), current.usable,
              current.bundleID == client.bundleIdentifier(), current.sameField(as: field),
              current.value == after.value else { return nil }
        let relative = NSRange(location: selection.range.location - range.location, length: selection.range.length)
        let nextText = (rendered as NSString).replacingCharacters(in: relative, with: replacement)
        return VoiceDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: nextText,
            range: NSRange(location: range.location, length: nextText.utf16.count), field: current, accessibility: accessibility)
    }
}

@MainActor private final class VoiceSystemRewriteAccessibility: VoiceRewriteAccessibility {
    static let shared = VoiceSystemRewriteAccessibility()
    var isTrusted: Bool { AXIsProcessTrusted() }

    private static let axLogger = Logger(subsystem: "app.zool.aime.voice", category: "rewrite")

    func focusedField() -> VoiceRewriteFieldSnapshot? {
        guard isTrusted, !SecureEventInputShield.isSecureEventInput(), let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else {
            Self.axLogger.notice("stage=axField nil reason=precondition trusted=\(self.isTrusted) secure=\(SecureEventInputShield.isSecureEventInput()) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "missing", privacy: .public)")
            return nil
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused = attribute(kAXFocusedUIElementAttribute, of: system)
        if focused == nil {
            // Type4Me activates enhanced AX when an Electron app has not yet
            // exposed its focused control. This changes no TCC permission.
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            if let window = attribute(kAXFocusedWindowAttribute, of: application),
               CFGetTypeID(window) == AXUIElementGetTypeID() {
                let element = window as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.15)
                _ = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            focused = attribute(kAXFocusedUIElementAttribute, of: system)
        }
        guard let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            Self.axLogger.notice("stage=axField nil reason=noFocusedElement bundle=\(bundle, privacy: .public)")
            return nil
        }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else {
            Self.axLogger.notice("stage=axField nil reason=pidMismatch bundle=\(bundle, privacy: .public) elementPid=\(pid) appPid=\(app.processIdentifier)")
            return nil
        }
        let role = attribute(kAXRoleAttribute, of: element) as? String ?? ""
        let subrole = attribute(kAXSubroleAttribute, of: element) as? String ?? ""
        // Reject secure controls before reading their value.
        guard ![role, subrole].contains(where: { $0.lowercased().contains("secure") || $0.lowercased().contains("password") }),
              let value = attribute(kAXValueAttribute, of: element) as? String else {
            Self.axLogger.notice("stage=axField nil reason=secureOrNoValue bundle=\(bundle, privacy: .public) role=\(role, privacy: .public) subrole=\(subrole, privacy: .public)")
            return nil
        }
        let selectedText = settable(kAXSelectedTextAttribute, of: element)
        let wholeValue = settable(kAXValueAttribute, of: element)
        let editable = selectedText || wholeValue || settable(kAXSelectedTextRangeAttribute, of: element)
        return VoiceRewriteFieldSnapshot(element: element, processID: pid, bundleID: bundle, value: value,
            selection: selection(of: element), isEditable: editable, selectedTextSettable: selectedText,
            valueSettable: wholeValue, singleLine: role == kAXTextFieldRole || role == "AXSearchField")
    }
    /// The client is the app that would receive the text: when the frontmost field belongs to
    /// another app there is no field to write and the message must say so.
    func focusedField(matching client: (any IMKTextInput)?) -> VoiceRewriteFieldSnapshot? {
        guard let field = focusedField() else { return nil }
        guard let client else { return field }
        guard field.bundleID == client.bundleIdentifier() else {
            Self.axLogger.notice("stage=axField nil reason=bundleMismatch fieldBundle=\(field.bundleID, privacy: .public) clientBundle=\(client.bundleIdentifier() ?? "nil", privacy: .public)")
            return nil
        }
        return field
    }
    func select(_ range: NSRange, in field: VoiceRewriteFieldSnapshot) -> Bool {
        guard let element = verifiedElement(field), validVoiceRange(range, in: field.value) else { return false }
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        // AXUIElementSetAttributeValue raises NSException for some clients and
        // Swift cannot catch that: one bad app would abort the input method.
        var outcome = AXError.failure
        ObjCException.guardCall("setSelectedTextRange") {
            outcome = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        return outcome == .success
    }
    func replaceSelectedText(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool {
        guard let element = verifiedElement(field), let current = focusedField(),
              current.selection == field.selection else { return false }
        var outcome = AXError.failure
        ObjCException.guardCall("setSelectedText") {
            outcome = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        }
        return outcome == .success
    }
    func replaceValue(_ text: String, in field: VoiceRewriteFieldSnapshot) -> Bool {
        guard let element = verifiedElement(field) else { return false }
        var outcome = AXError.failure
        ObjCException.guardCall("setValue") {
            outcome = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        }
        return outcome == .success
    }
    private func verifiedElement(_ field: VoiceRewriteFieldSnapshot) -> AXUIElement? {
        guard isTrusted, let current = focusedField(), current.usable, current.sameField(as: field),
              current.value == field.value, CFGetTypeID(field.element) == AXUIElementGetTypeID() else { return nil }
        return (field.element as! AXUIElement)
    }
    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func settable(_ name: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
    private func selection(of element: AXUIElement) -> NSRange? {
        guard let raw = attribute(kAXSelectedTextRangeAttribute, of: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

import Foundation
public import InputMethodKit
import os


/// IMK-only rewrite target, for apps whose input box is not exposed to
/// Accessibility (web-based editors such as the Muse composer, custom editors).
/// It never touches AX: the target comes from the IMK client's own selection
/// (manual select) or from a dictation origin verified through the client
/// (caret before/after commit + readback of the inserted span). All ranges are
/// IMK coordinates and are never mixed with AX coordinates. Writes are single
/// transactions with readback verification, mirroring VoiceRewriteSelection;
/// anything unverified fails closed without writing.
@MainActor public final class VoiceRewriteIMKSelection {
    public let text: String
    public let range: NSRange
    public let isRecentDictation: Bool
    /// IMK cannot tell whether a field is single-line, so this is always false.
    public let isSingleLine = false
    public private(set) var preparationFailureMessage: String?
    private let explicitSelection: NSRange?
    private var attempted = false
    /// The client cannot answer `attributedSubstring` for this span, so the target is
    /// proven by the caret sitting at its end (read while the event was handled).
    private let caretProven: Bool
    fileprivate var insertedText: String?
    fileprivate var insertedRange: NSRange?

    public init?(client: any IMKTextInput, imkOrigin: VoiceIMKDictationOrigin?) {
        guard client.markedRange().location == NSNotFound else { return nil }
        let selected = client.selectedRange()
        if selected.location != NSNotFound, selected.length > 0,
           let sub = client.attributedSubstring(from: selected)?.string,
           !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sub.count <= 2000 {
            text = sub; range = selected; isRecentDictation = false; explicitSelection = selected; caretProven = false
            return
        }
        guard let origin = imkOrigin, origin.matches(client: client), origin.rendered.count <= 2000,
              !origin.rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        text = origin.rendered; range = origin.range; isRecentDictation = true; explicitSelection = nil
        caretProven = origin.provenance == .caret
    }

    /// Verification only: IMK cannot move the selection, so unlike the AX path
    /// nothing is highlighted here. The insert itself uses an explicit range.
    public func prepare(in client: any IMKTextInput) async -> Bool {
        guard client.markedRange().location == NSNotFound else { return false }
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return false }
            if let explicitSelection {
                if NSEqualRanges(client.selectedRange(), explicitSelection), holdsOriginalText(client) { return true }
            } else if holdsOriginalText(client) {
                return true
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(40)) }
        }
        return false
    }

    /// nil means the single write was issued and verified by readback, not that
    /// the app rendered it. Never retries: a failed verification leaves the
    /// original text untouched.
    public func insert(_ replacement: String, into client: any IMKTextInput, allowEmpty: Bool = false) async -> VoiceCommitTarget.Rejection? {
        guard !attempted else { return .selectionChanged }
        guard allowEmpty || !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyResult }
        guard client.markedRange().location == NSNotFound else { return .selectionChanged }
        attempted = true
        guard holdsOriginalText(client) else {
            preparationFailureMessage = "原文已变化，未写入"
            return .contextChanged
        }
        client.insertText(replacement, replacementRange: range)
        if replacement.isEmpty {
            // Deletion: the caret must land at the start of the removed span.
            let caret = NSRange(location: range.location, length: 0)
            for attempt in 0..<9 {
                guard !Task.isCancelled else { return .contextChanged }
                if NSEqualRanges(client.selectedRange(), caret) {
                    insertedText = replacement; insertedRange = caret
                    return nil
                }
                if attempt < 8 { try? await Task.sleep(for: .milliseconds(40)) }
            }
            preparationFailureMessage = "输入框未确认改写结果，未重复写入"
            return .contextChanged
        }
        let newRange = NSRange(location: range.location, length: replacement.utf16.count)
        var unreadable = false
        for attempt in 0..<9 {
            guard !Task.isCancelled else { return .contextChanged }
            if let current = client.attributedSubstring(from: newRange)?.string {
                if current == replacement { insertedText = replacement; insertedRange = newRange; return nil }
            } else {
                unreadable = true
            }
            if attempt < 8 { try? await Task.sleep(for: .milliseconds(40)) }
        }
        // The write was issued but this client never answers `attributedSubstring`.
        // Accept it and record the span, so the next rewrite can re-prove the text
        // from a fresh client read inside the event handler. A client that does read
        // still fails closed here.
        guard unreadable else {
            preparationFailureMessage = "输入框未确认改写结果，未重复写入"
            return .contextChanged
        }
        VoiceIMKDictationOrigin.imkLogger.notice("stage=imkInsert unverified reason=clientCannotRead span=\(newRange.location) len=\(newRange.length)")
        insertedText = replacement; insertedRange = newRange
        return nil
    }

    /// True when the tracked span still holds the original text. Clients that cannot
    /// read ranges are accepted when the caret proves the span (only for spans this
    /// process inserted and that were proven the same way when the target was built).
    private func holdsOriginalText(_ client: any IMKTextInput) -> Bool {
        if let current = client.attributedSubstring(from: range)?.string { return current == text }
        guard caretProven else { return false }
        return NSEqualRanges(client.selectedRange(), NSRange(location: NSMaxRange(range), length: 0))
    }

    /// Origin for the just-written span, for the next rewrite in this field.
    /// Re-verifies the span still holds the replacement.
    public func committedOrigin(sessionID: UUID, transcript: String, client: any IMKTextInput) -> VoiceIMKDictationOrigin? {
        guard let insertedText, let insertedRange else { return nil }
        if client.attributedSubstring(from: insertedRange)?.string == insertedText {
            return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: insertedText,
                                           range: insertedRange, bundleID: client.bundleIdentifier(), provenance: .readback)
        }
        // Unreadable client: the origin is re-proved by the caret at the next rewrite.
        return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: insertedText,
                                       range: insertedRange, bundleID: client.bundleIdentifier(), provenance: .caret)
    }
}

/// IMK-only provenance for a verified dictation or rewrite span. Independent of
/// any AX field: identity is the client bundle plus the verified span text.
/// Only verified insertion/readback creates provenance, mirroring VoiceDictationOrigin.
@MainActor public struct VoiceIMKDictationOrigin {
    fileprivate static let imkLogger = Logger(subsystem: "app.zool.aime.voice", category: "rewrite")

    /// How strongly the span is known. Some clients (Qt apps such as QQ) never answer
    /// `attributedSubstring` for an arbitrary range, so a span we inserted ourselves
    /// can only be placed by arithmetic; the caret then proves it is still untouched.
    public enum Provenance: Sendable { case readback, caret }
    public let sessionID: UUID
    public let transcript: String
    public let rendered: String
    public let range: NSRange
    public let bundleID: String?
    public let provenance: Provenance

    public init(sessionID: UUID, transcript: String, rendered: String, range: NSRange, bundleID: String?,
                provenance: Provenance = .readback) {
        self.sessionID = sessionID; self.transcript = transcript; self.rendered = rendered; self.range = range
        self.bundleID = bundleID; self.provenance = provenance
    }

    private func bundleMatches(client: any IMKTextInput) -> Bool {
        guard let bundleID, !bundleID.isEmpty, let current = client.bundleIdentifier(), !current.isEmpty else { return true }
        return bundleID == current
    }

    /// True when the client reports an empty selection sitting exactly at the end of
    /// this span, i.e. our own insert is still the text right before the caret.
    fileprivate func caretHolds(client: any IMKTextInput) -> Bool {
        guard range.location != NSNotFound else { return false }
        return NSEqualRanges(client.selectedRange(), NSRange(location: NSMaxRange(range), length: 0))
    }

    public func matches(client: any IMKTextInput) -> Bool {
        guard range.location != NSNotFound, range.location >= 0, range.length == rendered.utf16.count,
              bundleMatches(client: client) else { return false }
        if client.attributedSubstring(from: range)?.string == rendered { return true }
        // The client cannot read the range; accept only if this origin was placed by its
        // own insert and the caret still sits at its end.
        return provenance == .caret && caretHolds(client: client)
    }

    public func owns(_ selection: VoiceRewriteIMKSelection, client: any IMKTextInput) -> Bool {
        guard matches(client: client), selection.range.location >= range.location,
              NSMaxRange(selection.range) <= NSMaxRange(range),
              client.attributedSubstring(from: selection.range)?.string == selection.text else { return false }
        return true
    }

    public func advanced(target selection: VoiceRewriteIMKSelection, replacement: String, client: any IMKTextInput) -> VoiceIMKDictationOrigin? {
        guard selection.insertedText == replacement, selection.range.location >= range.location,
              NSMaxRange(selection.range) <= NSMaxRange(range), bundleMatches(client: client) else { return nil }
        let relative = NSRange(location: selection.range.location - range.location, length: selection.range.length)
        let nextText = (rendered as NSString).replacingCharacters(in: relative, with: replacement)
        let nextRange = NSRange(location: range.location, length: nextText.utf16.count)
        // A rewrite readback is authoritative; the caret alone can place it.
        if client.attributedSubstring(from: nextRange)?.string == nextText {
            return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: nextText,
                                           range: nextRange, bundleID: bundleID, provenance: .readback)
        }
        guard NSEqualRanges(client.selectedRange(), NSRange(location: NSMaxRange(nextRange), length: 0)) else { return nil }
        return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: nextText,
                                       range: nextRange, bundleID: bundleID, provenance: .caret)
    }

    /// Provenance for the span a dictation was just committed into. The offset comes
    /// from the caret captured while the input event was handled: reading the proxy
    /// here (an async task after recognition) returns stale values on many clients.
    /// `length()` is queried for diagnostics only and never gates the result.
    public static func afterDictation(before: NSRange, text: String, transcript: String, sessionID: UUID, client: any IMKTextInput) async -> VoiceIMKDictationOrigin? {
        guard !text.isEmpty, text.count <= 2000, before.location != NSNotFound, before.location >= 0, before.length >= 0 else { return nil }
        let span = NSRange(location: before.location, length: text.utf16.count)
        let readback = client.attributedSubstring(from: span)?.string == text
        // Probe once so the log shows what this client can answer; nothing depends on it.
        let probeCaret = client.selectedRange()
        imkLogger.notice("stage=afterDictation span=\(span.location) len=\(span.length) readback=\(readback) provenance=\(readback ? "readback" : "caret") caretRead=\(probeCaret.location) docLen=\(client.length())")
        return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: text,
                                       range: span, bundleID: client.bundleIdentifier(),
                                       provenance: readback ? .readback : .caret)
    }
}

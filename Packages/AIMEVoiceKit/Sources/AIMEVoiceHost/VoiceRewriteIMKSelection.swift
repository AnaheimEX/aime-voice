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
    fileprivate var insertedText: String?
    fileprivate var insertedRange: NSRange?

    public init?(client: any IMKTextInput, imkOrigin: VoiceIMKDictationOrigin?) {
        guard client.markedRange().location == NSNotFound else { return nil }
        let selected = client.selectedRange()
        if selected.location != NSNotFound, selected.length > 0,
           let sub = client.attributedSubstring(from: selected)?.string,
           !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sub.count <= 2000 {
            text = sub; range = selected; isRecentDictation = false; explicitSelection = selected
            return
        }
        guard let origin = imkOrigin, origin.matches(client: client), origin.rendered.count <= 2000,
              !origin.rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        text = origin.rendered; range = origin.range; isRecentDictation = true; explicitSelection = nil
    }

    /// Verification only: IMK cannot move the selection, so unlike the AX path
    /// nothing is highlighted here. The insert itself uses an explicit range.
    public func prepare(in client: any IMKTextInput) async -> Bool {
        guard client.markedRange().location == NSNotFound else { return false }
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return false }
            if let explicitSelection {
                if NSEqualRanges(client.selectedRange(), explicitSelection),
                   client.attributedSubstring(from: range)?.string == text { return true }
            } else if client.attributedSubstring(from: range)?.string == text {
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
        guard client.attributedSubstring(from: range)?.string == text else {
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
        for attempt in 0..<9 {
            guard !Task.isCancelled else { return .contextChanged }
            if client.attributedSubstring(from: newRange)?.string == replacement {
                insertedText = replacement; insertedRange = newRange
                return nil
            }
            if attempt < 8 { try? await Task.sleep(for: .milliseconds(40)) }
        }
        preparationFailureMessage = "输入框未确认改写结果，未重复写入"
        return .contextChanged
    }

    /// Origin for the just-written span, for the next rewrite in this field.
    /// Re-verifies the span still holds the replacement.
    public func committedOrigin(sessionID: UUID, transcript: String, client: any IMKTextInput) -> VoiceIMKDictationOrigin? {
        guard let insertedText, let insertedRange else { return nil }
        guard client.attributedSubstring(from: insertedRange)?.string == insertedText else { return nil }
        return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: insertedText, range: insertedRange, bundleID: client.bundleIdentifier())
    }
}

/// IMK-only provenance for a verified dictation or rewrite span. Independent of
/// any AX field: identity is the client bundle plus the verified span text.
/// Only verified insertion/readback creates provenance, mirroring VoiceDictationOrigin.
@MainActor public struct VoiceIMKDictationOrigin {
    fileprivate static let imkLogger = Logger(subsystem: "app.zool.aime.voice", category: "rewrite")
    public let sessionID: UUID
    public let transcript: String
    public let rendered: String
    public let range: NSRange
    public let bundleID: String?

    public init(sessionID: UUID, transcript: String, rendered: String, range: NSRange, bundleID: String?) {
        self.sessionID = sessionID; self.transcript = transcript; self.rendered = rendered; self.range = range; self.bundleID = bundleID
    }

    private func bundleMatches(client: any IMKTextInput) -> Bool {
        guard let bundleID, !bundleID.isEmpty, let current = client.bundleIdentifier(), !current.isEmpty else { return true }
        return bundleID == current
    }

    public func matches(client: any IMKTextInput) -> Bool {
        guard range.location != NSNotFound, range.location >= 0, range.length == rendered.utf16.count,
              bundleMatches(client: client) else { return false }
        return client.attributedSubstring(from: range)?.string == rendered
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
        guard client.attributedSubstring(from: nextRange)?.string == nextText else { return nil }
        return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: nextText, range: nextRange, bundleID: bundleID)
    }

    /// Verified dictation origin from the caret before insertion and the caret
    /// after it. Retries briefly: some clients (web editors) apply the insert
    /// asynchronously, so the caret may lag the insert request.
    public static func afterDictation(before: NSRange, text: String, transcript: String, sessionID: UUID, client: any IMKTextInput) async -> VoiceIMKDictationOrigin? {
        guard !text.isEmpty, text.count <= 2000, before.location != NSNotFound, before.location >= 0, before.length >= 0 else { return nil }
        for attempt in 0..<9 {
            guard !Task.isCancelled else { return nil }
            let after = client.selectedRange()
            if let span = spanForInsert(before: before, after: after, text: text),
               client.attributedSubstring(from: span)?.string == text {
                return VoiceIMKDictationOrigin(sessionID: sessionID, transcript: transcript, rendered: text, range: span, bundleID: client.bundleIdentifier())
            }
            if attempt < 8 { try? await Task.sleep(for: .milliseconds(40)) }
        }
        // Diagnose why the span could not be verified: the caret placement or the
        // readback. Only positions and lengths are logged, never the dictated text.
        let after = client.selectedRange()
        let span = NSRange(location: before.location, length: text.utf16.count)
        let readback = client.attributedSubstring(from: span)?.string == text
        imkLogger.notice("stage=afterDictation nil reason=retriesExhausted beforeAt=\(before.location) afterLoc=\(after.location) afterLen=\(after.length) textLen=\(text.utf16.count) readback=\(readback) marked=\(client.markedRange().location != NSNotFound)")
        return nil
    }

    private static func spanForInsert(before: NSRange, after: NSRange, text: String) -> NSRange? {
        guard before.location <= Int.max - text.utf16.count else { return nil }
        let span = NSRange(location: before.location, length: text.utf16.count)
        let caretAtEnd = after.length == 0 && after.location == NSMaxRange(span)
        let selectedSpan = NSEqualRanges(after, span)
        guard caretAtEnd || selectedSpan else { return nil }
        return span
    }
}

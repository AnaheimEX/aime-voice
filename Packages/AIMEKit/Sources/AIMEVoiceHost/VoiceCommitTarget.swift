import AIMEVoice
import Foundation
public import InputMethodKit

/// A dictation result may only be inserted into the unchanged input session.
@MainActor
public final class VoiceCommitTarget {
    public enum Rejection: String, Sendable {
        case clientChanged, selectionChanged, contextChanged, emptyResult
    }

    private let client: any IMKTextInput
    private let bundleID: String?
    private let range: NSRange
    private let contextRange: NSRange
    private let context: String?

    public init(client: any IMKTextInput) {
        self.client = client
        bundleID = client.bundleIdentifier()
        range = client.selectedRange()
        if range.location != NSNotFound {
            let start = max(0, range.location - 32)
            contextRange = NSRange(location: start, length: range.location - start + range.length)
            context = client.attributedSubstring(from: contextRange)?.string
        } else {
            contextRange = NSRange(location: NSNotFound, length: 0)
            context = nil
        }
    }

    /// nil means the native insert request was issued, not that the app rendered it.
    public func insert(_ text: String, into current: any IMKTextInput) -> Rejection? {
        // uniqueClientIdentifierString generates a unique string; it is not a
        // persistent identity to compare across calls. The owning controller
        // also cancels this target when its input session is deactivated.
        let sameProxy = ObjectIdentifier(current as AnyObject) == ObjectIdentifier(client as AnyObject)
        guard sameProxy, current.bundleIdentifier() == bundleID else { return .clientChanged }
        guard NSEqualRanges(current.selectedRange(), range) else { return .selectionChanged }
        guard context == nil || current.attributedSubstring(from: contextRange)?.string == context else { return .contextChanged }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyResult }
        // The selection was just verified. Dictation inserts there, rather than
        // asking the app to perform an absolute document-range replacement.
        current.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return nil
    }
}

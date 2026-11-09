import AIMEVoice
public import Foundation
public import InputMethodKit

/// Process-wide receipt survives IMK controller churn; actual field identity is
/// checked by the rewrite target. Never persists input text to disk.
/// Two parallel provenances exist: the AX one (`origin`) for apps that expose the
/// focused field to Accessibility, and the IMK one (`imkOrigin`) for apps that do
/// not (Qt and web editors), where the rewrite must run through the client itself.
@MainActor public final class VoiceRecentDictation {
    private var origin: VoiceDictationOrigin?
    private var pending: Task<VoiceDictationOrigin?, Never>?
    private var imkOrigin: VoiceIMKDictationOrigin?
    private var pendingIMK: Task<VoiceIMKDictationOrigin?, Never>?
    private var generation = UUID()
    private var recordedAt = Date.distantPast

    public init() {}

    public func replace(_ origin: VoiceDictationOrigin?) {
        pending?.cancel()
        pending = nil
        generation = UUID()
        self.origin = origin
        recordedAt = Date()
    }

    /// AX rewrite provenance; nil when the app exposes no focused control, so the
    /// rewrite falls back to the IMK client and proves the span by readback.
    public func replaceIMK(_ origin: VoiceIMKDictationOrigin?) {
        pendingIMK?.cancel()
        pendingIMK = nil
        imkOrigin = origin
    }

    public func track(anchor: VoiceDictationAnchor?, sessionID: UUID, transcript: String,
                      committed: String, client: any IMKTextInput) {
        replace(nil)
        guard let anchor else { return }
        pending = Task { @MainActor in
            await anchor.resolve(sessionID: sessionID, transcript: transcript,
                                 committed: committed, client: client)
        }
    }

    /// IMK provenance for the just-committed span: caret before the insert plus
    /// readback of the span afterwards. Resolves asynchronously because some
    /// clients apply the insert on a later run-loop turn.
    public func trackIMK(before caret: NSRange, sessionID: UUID, transcript: String,
                         text: String, client: any IMKTextInput) {
        replaceIMK(nil)
        guard caret.location != NSNotFound else { return }
        pendingIMK = Task { @MainActor in
            await VoiceIMKDictationOrigin.afterDictation(before: caret, text: text,
                transcript: transcript, sessionID: sessionID, client: client)
        }
    }

    public func latest() async -> VoiceDictationOrigin? {
        guard Date().timeIntervalSince(recordedAt) <= 300 else { replace(nil); return nil }
        if let pending {
            let expected = generation
            let resolved = await pending.value
            guard expected == generation, !Task.isCancelled else { return nil }
            origin = resolved
            self.pending = nil
        }
        return origin
    }

    public func latestIMK() async -> VoiceIMKDictationOrigin? {
        if let pendingIMK {
            let resolved = await pendingIMK.value
            guard !Task.isCancelled else { return nil }
            imkOrigin = resolved
            self.pendingIMK = nil
        }
        return imkOrigin
    }
}

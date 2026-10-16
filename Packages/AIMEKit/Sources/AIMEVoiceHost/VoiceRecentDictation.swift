import AIMEVoice
public import Foundation
public import InputMethodKit

/// Process-wide receipt survives IMK controller churn; actual field identity is
/// checked by the rewrite target. Never persists input text to disk.
@MainActor public final class VoiceRecentDictation {
    private var origin: VoiceDictationOrigin?
    private var pending: Task<VoiceDictationOrigin?, Never>?
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

    public func track(anchor: VoiceDictationAnchor?, sessionID: UUID, transcript: String,
                      committed: String, client: any IMKTextInput) {
        replace(nil)
        guard let anchor else { return }
        pending = Task { @MainActor in
            await anchor.resolve(sessionID: sessionID, transcript: transcript,
                                 committed: committed, client: client)
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
}

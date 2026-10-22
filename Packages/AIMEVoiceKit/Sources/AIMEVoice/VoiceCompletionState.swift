public import Foundation

/// Shared completion path: ordinary dictation and rewrite both commit automatically.
public struct VoiceCompletionState: Sendable {
    public enum Action: Equatable, Sendable {
        case ignored, invalid, commit(String)
    }
    private let sessionID: String
    private let isRewrite: Bool
    private var completed = false
    public private(set) var transcript = ""
    public private(set) var processing: VoicePolishObservation.Processing?

    public init(sessionID: String, isRewrite: Bool = false) {
        self.sessionID = sessionID
        self.isRewrite = isRewrite
    }

    public mutating func receive(_ event: VoiceEvent) -> Action {
        guard !completed, event.sessionID == sessionID, event.kind == "completed" else { return .ignored }
        guard isRewrite || !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalid }
        completed = true
        transcript = event.transcript ?? ""
        processing = event.processing
        return .commit(event.text)
    }
}

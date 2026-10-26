public import Foundation
public import AppKit
public import InputMethodKit

public struct InputOwner: Hashable, Sendable {
    private let id: UUID
    public init() { id = UUID() }
}

@MainActor public struct InputSnapshot {
    public let client: any IMKTextInput
    public let canStart: Bool
    public let canCommit: Bool
    public init(client: any IMKTextInput, canStart: Bool, canCommit: Bool) {
        self.client = client; self.canStart = canStart; self.canCommit = canCommit
    }
}
public enum KeyDisposition: Equatable, Sendable { case consumed, passThrough }
public enum HostPresentation: Sendable { case status(String), hideCandidates, restorePanel }
public enum VoiceFeedback: Sendable {
    public enum State: Sendable, Equatable { case preparing, recording, transcribing, processing, rewriting, translating }
    case state(State), level(Float), cue(recording: Bool), hide
}
@MainActor public protocol VoiceHost: AnyObject {
    func snapshot(for owner: InputOwner) -> InputSnapshot?
    func present(_ effect: HostPresentation, for owner: InputOwner)
}

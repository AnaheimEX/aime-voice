public import Foundation

/// Local RPC only. Audio and provider credentials never use distributed notifications.
@objc public protocol VoiceServiceProtocol {
    func start(_ request: Data, reply: @escaping (Bool, String) -> Void)
    func stop(_ sessionID: String)
    func cancel(_ sessionID: String)
    func ping(_ reply: @escaping () -> Void)
    /// Best-effort idle graph setup; never requests permission or starts capture.
    func warmUp(_ reply: @escaping (Bool) -> Void)
}

@objc public protocol VoiceObserverProtocol {
    func receive(_ event: Data)
}

public struct VoiceRequest: Codable, Sendable {
    public var sessionID: String
    public var settings: VoiceSettings
    /// Non-nil selects rewrite mode; the ASR transcript becomes the editing instruction.
    public var rewriteText: String?
    public var rewriteSingleLine: Bool?
    public init(sessionID: String, settings: VoiceSettings, rewriteText: String? = nil, rewriteSingleLine: Bool? = nil) {
        self.sessionID = sessionID
        self.settings = settings
        self.rewriteText = rewriteText
        self.rewriteSingleLine = rewriteSingleLine
    }
}

public struct VoiceEvent: Codable, Sendable {
    public var sessionID: String
    public var kind: String
    public var text: String
    public var level: Double
    /// Original ASR text, before polishing or selection rewriting.
    public var transcript: String?
    public var processing: VoicePolishObservation.Processing?
    public init(sessionID: String, kind: String, text: String = "", level: Double = 0, transcript: String? = nil,
                processing: VoicePolishObservation.Processing? = nil) {
        self.sessionID = sessionID
        self.kind = kind
        self.text = text
        self.level = level
        self.transcript = transcript
        self.processing = processing
    }
}


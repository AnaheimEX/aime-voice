import Carbon.HIToolbox
import Darwin

/// Secure-input states (password fields, the lock screen, some enterprise apps)
/// require the microphone to be closed even if a hotkey was pressed.
///
/// `VoiceFeature` already passes the focus path; this guard sits at the
/// recording boundary so a hot-pressed dictation never opens the mic in a
/// secure state.
public enum SecureEventInputShield {

    /// Tracked so the recording boundary can be unit-tested without a secure
    /// input session on the test machine. Nil is the live call.
    public nonisolated(unsafe) static var probe: () -> Bool = { IsSecureEventInputEnabled() }

    public static func isSecureEventInput() -> Bool {
        probe()
    }

    /// Throws if the microphone must not be opened.
    static func guardRecording() throws {
        guard !isSecureEventInput() else { throw VoiceCaptureError.secureInput }
    }
}

import AVFoundation
@preconcurrency import ApplicationServices
import AppKit
import Foundation
import OSLog

/// Requests the macOS permissions the voice features need, in the order that
/// produces the Fewest confusing dialogs.
///
/// The recorder starts the microphone only the first time it is used and the
/// accessibility dialog only on the *shortcut* path; if the user has to wait
/// for a permission prompt in the middle of a recording, the audio is wasted.
/// This module asks the missing grants proactively.
public enum PermissionBootstrap {

    /// Request the missing grants now, so the voice features never prompt while
    /// the user is typing. The order matters: `AXIsProcessTrustedWithOptions`
    /// must be asked first because its system dialog takes longer to appear.
    public static func requestAll() async -> Bool {
        let accessibility = requestAccessibility()
        let microphone = await requestMicrophone()
        return accessibility && microphone
    }

    /// Accessibility: reading text boxes, setting selections, AX hot words.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // Already granted: never re-prompt the user.
        guard !AXIsProcessTrusted() else { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            PermissionBootstrap.logger.warning("accessibility not granted yet — AX context/hot words disabled")
        }
        return trusted
    }

    /// Microphone: the operating system prompt takes over the foreground input,
    /// so it must be cleared up front.
    @discardableResult
    public static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let logger = Self.logger
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    logger.notice("mic permission \(allowed ? "granted" : "denied")")
                    if !allowed {
                        logger.warning("microphone permission not granted — voice unchanged")
                    }
                    continuation.resume(returning: allowed)
                }
            }
        default:
            return false
        }
    }

    /// Jump straight to the Accessibility pane so the user does not have to hunt
    /// for it after a paste was refused.
    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Jump straight to the Microphone pane.
    public static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// Grant state, for the settings window.
    public struct Status {
        public let accessibility: Bool
        public let microphone: Bool

        public var allGranted: Bool { accessibility && microphone }
    }

    public static func currentStatus() -> Status {
        let accessibility = AXIsProcessTrusted()
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return Status(accessibility: accessibility, microphone: microphone)
    }
}

extension PermissionBootstrap {
    private static let logger = Logger(subsystem: "app.zool.aime", category: "permission")
}

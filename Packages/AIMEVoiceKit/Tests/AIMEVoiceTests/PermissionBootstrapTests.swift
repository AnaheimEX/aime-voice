import AVFoundation
import AIMEVoiceHost
import XCTest

/// The bootstrap grants are asked in an order that never shadows a hotkey: the
/// accessibility dialog takes longer to appear (and only pings the Accessibility
/// focus) before the microphone prompt takes over the foreground.
final class PermissionBootstrapTests: XCTestCase {

    /// `currentStatus` can answer the user's own question without prompting.
    func testStatusReflectsGrants() {
        let status = PermissionBootstrap.currentStatus()
        XCTAssertEqual(status.accessibility, AXIsProcessTrusted())
        XCTAssertEqual(status.microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        XCTAssertEqual(status.allGranted, status.accessibility && status.microphone)
    }


    /// Both panels can be opened from the app without crashing.
    func testOpenSettingsPanels() {
        PermissionBootstrap.openAccessibilitySettings()
        PermissionBootstrap.openMicrophoneSettings()
    }
}

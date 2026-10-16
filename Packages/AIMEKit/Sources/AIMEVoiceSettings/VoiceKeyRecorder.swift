import AIMEVoice
import AppKit
import SwiftUI

/// Voice-only recorder. Rime's shared shortcut recorder keeps its existing policy.
struct VoiceKeyRecorder: NSViewRepresentable {
    let value: String
    let commit: (String) -> Void

    func makeNSView(context: Context) -> VoiceRecorderButton { VoiceRecorderButton() }

    func updateNSView(_ button: VoiceRecorderButton, context: Context) {
        button.idleTitle = VoiceShortcutConfiguration.display(value)
        button.commit = commit
        button.isEnabled = context.environment.isEnabled
        if !button.isEnabled { button.stop() }
        button.refreshTitle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: VoiceRecorderButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    static func dismantleNSView(_ button: VoiceRecorderButton, coordinator: ()) { button.stop() }
}

@MainActor
final class VoiceRecorderButton: NSButton {
    var idleTitle = "未设置"
    var commit: (String) -> Void = { _ in }
    private var active = false
    private var waitingExistingModifiers = false
    private var pending: String?
    private var heldKeys: Set<UInt16> = []
    private var modifierKeys: Set<UInt16> = []
    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private var timeout: Task<Void, Never>?
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    override var acceptsFirstResponder: Bool { true }
    override var inputContext: NSTextInputContext? { nil }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(112, size.width), height: max(28, size.height))
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        target = self
        action = #selector(toggleRecording)
        toolTip = "点击后按单键、功能键、左/右修饰键或组合键，全部松开后保存；再次点击取消"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func toggleRecording() {
        if active { stop(); return }
        guard let window, window.makeFirstResponder(self) else { NSSound.beep(); return }
        stop()
        active = true
        waitingExistingModifiers = !NSEvent.modifierFlags.intersection(Self.shortcutModifiers).isEmpty
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { @Sendable [weak self, weak window] event in
            // AppKit invokes local monitors synchronously on its main event loop.
            nonisolated(unsafe) let localEvent = event
            let consumed = MainActor.assumeIsolated {
                guard let self, self.active, let window, window.isKeyWindow,
                      localEvent.window == nil || localEvent.window === window else { return false }
                self.record(localEvent)
                return true
            }
            return consumed ? nil : event
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.stop()
        }
    }

    private func record(_ event: NSEvent) {
        let modifiersReleased = event.modifierFlags.intersection(Self.shortcutModifiers).isEmpty
        if waitingExistingModifiers {
            if modifiersReleased { waitingExistingModifiers = false }
            refreshTitle()
            return
        }
        switch event.type {
        case .keyDown:
            heldKeys.insert(event.keyCode)
            if !event.isARepeat, pending == nil {
                pending = VoiceShortcutConfiguration.keyName(keyCode: event.keyCode,
                    character: event.charactersIgnoringModifiers, flags: event.modifierFlags.rawValue)
                if pending == nil { NSSound.beep() }
            }
        case .keyUp: heldKeys.remove(event.keyCode)
        case .flagsChanged:
            if VoiceShortcutConfiguration.modifierIsPressed(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) {
                modifierKeys.insert(event.keyCode)
            }
        default: return
        }
        if heldKeys.isEmpty, modifiersReleased {
            let modifier = modifierKeys.count == 1 ? modifierKeys.first.flatMap(VoiceShortcutConfiguration.modifierName) : nil
            if let name = pending ?? modifier {
                stop()
                commit(name)
                return
            }
            modifierKeys.removeAll()
        }
        refreshTitle()
    }

    func stop() {
        active = false
        pending = nil
        heldKeys.removeAll()
        modifierKeys.removeAll()
        waitingExistingModifiers = false
        timeout?.cancel()
        timeout = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        refreshTitle()
    }

    func refreshTitle() {
        title = active ? (waitingExistingModifiers ? "请先松开按键…" : "按键后松开保存…") : idleTitle
    }

    override func resignFirstResponder() -> Bool { stop(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}

public import Foundation
public import AIMEVoice
public import AppKit
@preconcurrency import ApplicationServices
import Carbon
public import InputMethodKit
import OSLog

private let voiceLatencyLogger = Logger(subsystem: "app.zool.aime.voice", category: "latency")

@MainActor
public final class VoiceFeature {
    private let host: any VoiceHost
    private let settingsURL: URL
    private let channel: VoiceServiceChannel
    private let feedback: @MainActor (VoiceFeedback) -> Void
    private let captureAnchor: @MainActor (any IMKTextInput) -> VoiceDictationAnchor?
    private let recentVoice = VoiceRecentDictation()
    private var voice: VoiceInputSession?
    private var voicePreparation: Task<Void, Never>?
    private var voiceKeyState = VoiceKeyState()
    private var activeOwner: InputOwner?
    private var shortcuts = VoiceShortcutConfiguration()
    private var observers: [any NSObjectProtocol] = []
    private var activationTask: Task<Void, Never>?
    private var snapshot: InputSnapshot? { activeOwner.flatMap { host.snapshot(for: $0) } }

    public init(host: any VoiceHost, settingsURL: URL = VoiceSettings.settingsURL,
                makeConnection: (() -> NSXPCConnection)? = nil,
                feedback: (@MainActor (VoiceFeedback) -> Void)? = nil,
                captureAnchor: (@MainActor (any IMKTextInput) -> VoiceDictationAnchor?)? = nil) {
        self.captureAnchor = captureAnchor ?? { VoiceDictationAnchor.capture(client: $0) }
        self.host = host
        self.settingsURL = settingsURL
        self.channel = makeConnection.map { VoiceServiceChannel(makeConnection: $0) } ?? VoiceServiceChannel()
        self.feedback = feedback ?? { effect in
            switch effect {
            case .cue(let recording): VoiceRecordingCue.play(recording: recording)
            case .hide: VoiceStatusOverlay.shared.hide()
            case .level(let value): VoiceStatusOverlay.shared.updateLevel(value)
            case .state(let state):
                let overlay: VoiceStatusOverlay.State
                switch state {
                case .preparing: overlay = .preparing
                case .recording: overlay = .recording
                case .transcribing: overlay = .transcribing
                case .processing: overlay = .processing
                case .rewriting: overlay = .rewriting
                }
                VoiceStatusOverlay.shared.show(state: overlay)
            }
        }
        reloadShortcuts()
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init(VoiceSettings.changedNotification), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadShortcuts()
                if !self.shortcuts.enabled { self.cancelVoice() }
                self.channel.warmUpIfAuthorized(enabled: self.shortcuts.enabled)
            }
        })
        observers.append(center.addObserver(forName: .init("app.zool.aime.voice.requestAccessibility"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                let trusted = AXIsProcessTrustedWithOptions(options)
                self?.showStatus(trusted ? "辅助功能已授权" : "请允许输入法的辅助功能权限")
            }
        })
    }

    public func activate(_ owner: InputOwner) {
        if activeOwner != owner { cancelVoice(restorePanel: false); voiceKeyState = VoiceKeyState() }
        activeOwner = owner
        activationTask?.cancel()
        // IMK activation must return before any call to its client.
        activationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.activeOwner == owner else { return }
            self.channel.warmUpIfAuthorized(enabled: self.shortcuts.enabled)
        }
    }

    public func handle(_ event: NSEvent, owner: InputOwner) -> KeyDisposition {
        guard activeOwner == owner else { return .passThrough }
        return handleVoiceKey(event, client: snapshot?.client) ? .consumed : .passThrough
    }

    public func deactivate(_ owner: InputOwner) {
        guard activeOwner == owner else { return }
        activationTask?.cancel()
        cancelVoice()
        activeOwner = nil
        voiceKeyState = VoiceKeyState()
    }

    public func shutdown() {
        if let owner = activeOwner { deactivate(owner) }
        channel.warmUpIfAuthorized(enabled: false)
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
    }

    public var isIdle: Bool { voice == nil && voicePreparation == nil }

    private func reloadShortcuts() {
        shortcuts = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(VoiceShortcutConfiguration.self, from: $0) } ?? VoiceShortcutConfiguration()
    }
    private func loadSettings() -> VoiceSettings {
        (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(VoiceSettings.self, from: $0) } ?? VoiceSettings()
    }
    private func present(_ effect: HostPresentation) {
        guard let owner = activeOwner else { return }
        host.present(effect, for: owner)
    }
    private func showStatus(_ text: String) { present(.status(text)) }

    struct VoiceKeyState {
        private var pressedModifiers: Set<UInt16> = []
        private var consumedKeys: Set<UInt16> = []

        mutating func modifierTransition(_ event: NSEvent) -> Bool? {
            guard VoiceShortcutConfiguration.modifierName(keyCode: event.keyCode) != nil else { return nil }
            let down = VoiceShortcutConfiguration.modifierIsPressed(keyCode: event.keyCode, flags: event.modifierFlags.rawValue)
            if down { return pressedModifiers.insert(event.keyCode).inserted ? true : nil }
            return pressedModifiers.remove(event.keyCode) != nil ? false : nil
        }

        mutating func consumeDown(_ keyCode: UInt16) { consumedKeys.insert(keyCode) }
        mutating func consumeUp(_ keyCode: UInt16) -> Bool { consumedKeys.remove(keyCode) != nil }
        func isConsumed(_ keyCode: UInt16) -> Bool { consumedKeys.contains(keyCode) }
    }

    @MainActor final class VoiceInputSession {
        let id: String
        let bridge: VoiceServiceBridge
        let target: VoiceCommitTarget
        let rewriteSelection: VoiceRewriteSelection?
        let origin: VoiceDictationOrigin?
        let settings: VoiceSettings
        var completion: VoiceCompletionState
        var transcript: String { completion.transcript }
        var anchor: VoiceDictationAnchor?
        var anchorTask: Task<Void, Never>?
        let toggleShortcut: String
        let cancelShortcut: String
        let recordingGesture: String
        let recordingKeyCode: UInt16
        var task: Task<Void, Never>?
        var stopping = false
        var recording = false

        init(bridge: VoiceServiceBridge, client: any IMKTextInput, settings: VoiceSettings, recordingKeyCode: UInt16,
             rewriteSelection: VoiceRewriteSelection? = nil, origin: VoiceDictationOrigin? = nil) {
            self.bridge = bridge
            id = UUID().uuidString
            completion = VoiceCompletionState(sessionID: id, isRewrite: rewriteSelection != nil)
            target = VoiceCommitTarget(client: client)
            self.rewriteSelection = rewriteSelection
            self.origin = origin
            self.settings = settings
            toggleShortcut = rewriteSelection == nil ? settings.toggleShortcut : settings.rewriteShortcut
            cancelShortcut = settings.cancelShortcut
            recordingGesture = rewriteSelection == nil ? settings.recordingGesture : "toggle"
            self.recordingKeyCode = recordingKeyCode

        }
    }

    /// Voice owns no Rime composition. Keyboard edits invalidate the pending result.
    func handleVoiceKey(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        let isPress: Bool
        switch event.type {
        case .keyDown: isPress = true
        case .keyUp: isPress = false
        case .flagsChanged:
            guard let transition = voiceKeyState.modifierTransition(event) else {
                return voiceKeyState.isConsumed(event.keyCode)
            }
            isPress = transition
        default: return false
        }

        if !isPress {
            let consumed = voiceKeyState.consumeUp(event.keyCode)
            if let active = voice, active.recordingGesture == "hold" {
                if event.keyCode == active.recordingKeyCode {
                    stopVoiceRecording(active)
                } else if event.type == .flagsChanged {
                    let required = active.toggleShortcut.split(separator: "+").dropLast()
                    let missingRequiredModifier = required.contains { part in
                        switch part {
                        case "Control": !event.modifierFlags.contains(.control)
                        case "Alt": !event.modifierFlags.contains(.option)
                        case "Shift": !event.modifierFlags.contains(.shift)
                        case "Super": !event.modifierFlags.contains(.command)
                        default: false
                        }
                    }
                    if missingRequiredModifier { stopVoiceRecording(active) }
                }
            }
            // Only consume releases whose presses belonged to voice. Ordinary typing key-up passes through.
            return consumed
        }

        if event.type == .keyDown, event.isARepeat, voiceKeyState.isConsumed(event.keyCode) { return true }
        let shortcuts = self.shortcuts
        let toggle = voice?.toggleShortcut ?? shortcuts.toggleShortcut
        let cancel = voice?.cancelShortcut ?? shortcuts.cancelShortcut
        let name = voiceKeyName(event)
        if name == shortcuts.rewriteShortcut, voice == nil, shortcuts.enabled {
            if voicePreparation != nil { cancelVoice(); return true }
            voiceKeyState.consumeDown(event.keyCode)
            // isARepeat is only defined for key events; a bare-modifier shortcut arrives as flagsChanged.
            if event.type != .keyDown || !event.isARepeat { startVoice(client: client, recordingKeyCode: event.keyCode, rewriting: true) }
            return true
        }
        if name == toggle, voice != nil || shortcuts.enabled {
            if voicePreparation != nil { cancelVoice() }
            voiceLatencyLogger.notice("Voice shortcut matched keyCode=\(event.keyCode, privacy: .public) flags=\(event.modifierFlags.rawValue, privacy: .public)")
            voiceKeyState.consumeDown(event.keyCode)
            if event.type == .keyDown, event.isARepeat { return true }
            if let voice {
                if voice.recordingGesture != "hold" { stopVoiceRecording(voice) }
            } else { startVoice(client: client, recordingKeyCode: event.keyCode) }
            return true
        }
        if voice != nil || voicePreparation != nil, name == cancel || name == "Escape" {
            voiceKeyState.consumeDown(event.keyCode)
            cancelVoice()
            showStatus("语音任务已取消")
            return true
        }
        // Modifier transitions are not text edits. An ordinary key still invalidates pending dictation.
        if event.type == .keyDown, voice != nil || voicePreparation != nil { cancelVoice() }
        return false
    }

    private func stopVoiceRecording(_ session: VoiceInputSession) {
        guard !session.stopping else { return }
        session.stopping = true
        if session.recording { session.bridge.stop() }
        feedback(.state(.transcribing))
    }

    private func voiceKeyName(_ event: NSEvent) -> String? {
        if event.type == .flagsChanged {
            return VoiceShortcutConfiguration.modifierName(keyCode: event.keyCode)
        }
        return VoiceShortcutConfiguration.keyName(keyCode: event.keyCode,
            character: event.charactersIgnoringModifiers, flags: event.modifierFlags.rawValue)
    }

    private func startVoice(client: (any IMKTextInput)?, recordingKeyCode: UInt16, rewriting: Bool = false) {
        let settings = loadSettings()
        guard settings.enabled else { showStatus("语音未开启：设置 › 语音输入"); return }
        guard !IsSecureEventInputEnabled() else { showStatus("安全输入状态下不能录音"); return }
        guard snapshot?.canStart == true else {
            showStatus("请先确认当前输入，再开始语音")
            return
        }
        guard let client else { return }
        if rewriting {
            voicePreparation = Task { @MainActor [weak self] in
                let origin = await self?.recentVoice.latest()
                guard !Task.isCancelled, let self else { return }
                guard let current = self.snapshot?.client else { self.voicePreparation = nil; return }
                guard let selection = VoiceRewriteSelection(client: current, origin: origin) else {
                    self.voicePreparation = nil
                    let reason = VoiceRewriteSelection.targetFailureReason(client: current, origin: origin)
                    voiceLatencyLogger.notice("stage=rewritePrepare failed reason=\(String(describing: reason), privacy: .public) hasOrigin=\(origin != nil) clientBundle=\(current.bundleIdentifier() ?? "nil", privacy: .public)")
                    showStatus(VoiceRewriteSelection.preparationFailureMessage(client: current, origin: origin))
                    return
                }
                let prepared = await selection.prepare(in: current)
                guard !Task.isCancelled else { return }
                self.voicePreparation = nil
                guard prepared, self.snapshot?.canStart == true else {
                    showStatus("无法确认改写选区，原文未改动")
                    return
                }
                self.beginVoice(client: current, settings: settings, recordingKeyCode: recordingKeyCode,
                                selection: selection, origin: origin.flatMap { $0.owns(selection, client: current) ? $0 : nil })
            }
            return
        }
        guard client.selectedRange().location != NSNotFound else {
            showStatus("当前应用未提供输入位置，不能安全提交语音结果")
            return
        }
        beginVoice(client: client, settings: settings, recordingKeyCode: recordingKeyCode, selection: nil, origin: nil)
    }

    private func beginVoice(client: any IMKTextInput, settings: VoiceSettings,
                            recordingKeyCode: UInt16, selection: VoiceRewriteSelection?, origin: VoiceDictationOrigin?) {
        let session = VoiceInputSession(bridge: VoiceServiceBridge(channel: channel), client: client, settings: settings, recordingKeyCode: recordingKeyCode,
                                        rewriteSelection: selection, origin: origin)
        voice = session
        session.bridge.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.voice === session else { return }
            switch event.kind {
            case "recording":
                guard !session.recording else { return }
                session.recording = true
                feedback(.cue(recording: true))
                if session.rewriteSelection == nil, AXIsProcessTrusted() {
                    session.anchorTask = Task { @MainActor [weak self, weak session] in
                        for attempt in 0..<3 {
                            guard !Task.isCancelled, let self, let session, self.voice === session else { return }
                            session.anchor = self.captureAnchor(client)
                            if session.anchor != nil { return }
                            // Enhanced AX can expose an Electron editor on the next run-loop turn.
                            if attempt < 2 { try? await Task.sleep(for: .milliseconds(40)) }
                        }
                    }
                }
                if session.stopping { session.bridge.stop() }
                else {
                    feedback(.state(.recording))
                }
            case "partial":
                // Recognition hypotheses stay internal; only the final polished result is committed.
                break
            case "level":
                if !session.stopping { feedback(.level(Float(event.level))) }
            case "transcribing":
                if session.recording { feedback(.cue(recording: false)) }
                session.recording = false
                feedback(.state(.transcribing))
            case "processing": feedback(.state(session.rewriteSelection == nil ? .processing : .rewriting))
            case "completed":
                switch session.completion.receive(event) {
                case .commit(let text):
                    session.task = Task { @MainActor [weak self] in await self?.commitVoice(text, session: session) }
                case .invalid:
                    self.cancelVoice()
                    showStatus("没有可用的改写结果")
                case .ignored: break
                }
            case "error":
                self.cancelVoice()
                showStatus(event.text)
            case "cancelled": self.cancelVoice()
            default: break
            }
        }
        feedback(.state(.preparing))
        session.task = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do { try await session.bridge.start(VoiceRequest(sessionID: session.id, settings: settings, rewriteText: selection?.text,
                                                                 rewriteSingleLine: selection?.isSingleLine)) }
            catch {
                guard self.voice === session else { return }
                self.cancelVoice()
                if !(error is CancellationError) { showStatus(error.localizedDescription) }
            }
        }
    }

    func cancelVoice(restorePanel: Bool = true) {
        voicePreparation?.cancel()
        voicePreparation = nil
        guard let session = voice else { return }
        session.task?.cancel()
        session.anchorTask?.cancel()
        session.bridge.cancel()
        voice = nil
        feedback(.hide)
        if restorePanel {
            present(.restorePanel)
        }
    }

    private func commitVoice(_ text: String, session: VoiceInputSession) async {
        let commitStarted = ContinuousClock.now
        defer { if voice === session { cancelVoice() } }
        // The cleanup above restores the candidate panel, which would hide a message shown just before it.
        // Release the session first on a rejection; the message then hides itself and restores the panel.
        func reject(_ message: String) {
            if voice === session { cancelVoice(restorePanel: false) }
            showStatus(message)
        }
        if session.rewriteSelection == nil { await session.anchorTask?.value }
        guard !Task.isCancelled, voice === session, !IsSecureEventInputEnabled(),
              let snapshot, snapshot.canCommit else {
            voiceLatencyLogger.notice("commitRejected=inactive_or_composing")
            reject("输入位置已变化，语音结果未写入")
            return
        }
        let current = snapshot.client
        present(.hideCandidates)
        let rejection: VoiceCommitTarget.Rejection?
        if let selection = session.rewriteSelection { rejection = await selection.insert(text, into: current, allowEmpty: text.isEmpty) }
        else { rejection = session.target.insert(text, into: current) }
        if let rejection {
            voiceLatencyLogger.notice("commitRejected=\(rejection.rawValue, privacy: .public) app=\(current.bundleIdentifier() ?? "?", privacy: .public)")
            reject(session.rewriteSelection?.preparationFailureMessage ?? "输入位置已变化，语音结果未写入")
            return
        }
        if let selection = session.rewriteSelection {
            let updated: VoiceDictationOrigin?
            if let origin = session.origin {
                updated = origin.advanced(target: selection, replacement: text, client: current)
            } else {
                updated = UUID(uuidString: session.id).flatMap { selection.committedOrigin(sessionID: $0, transcript: "") }
            }
            recentVoice.replace(updated)
        } else if let id = UUID(uuidString: session.id) {
            recentVoice.track(anchor: session.anchor, sessionID: id,
                transcript: session.transcript, committed: text, client: current)
        }
        let elapsed = commitStarted.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        voiceLatencyLogger.notice("commitMs=\(milliseconds) app=\(current.bundleIdentifier() ?? "?", privacy: .public)")
        if session.rewriteSelection == nil, let processing = session.completion.processing {
            VoicePolishObservation.recordAfterCommit(transcript: session.transcript, committed: text,
                                                    settings: session.settings, processing: processing)
        }
    }
}

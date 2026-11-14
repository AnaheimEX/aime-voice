import Foundation
import InputMethodKit
import AppKit
import AIMEVoice
import AIMEVoiceHost

// External IMK transport boundary. A generated string cannot prove client identity.
final class Document {
    var text = "前文"
    var selection = NSRange(location: 2, length: 0)
}
final class Client: NSObject, IMKTextInput {
    let document: Document
    var identity: String
    var generatesIdentifier = false
    var application = "app.test.editor"
    var currentSelectionOnly = false
    init(_ document: Document, id: String = "field-a") { self.document = document; identity = id }
    func insertText(_ value: Any!, replacementRange: NSRange) {
        if currentSelectionOnly && replacementRange.location != NSNotFound { return }
        let range = replacementRange.location == NSNotFound ? document.selection : replacementRange
        let text = value as! String
        document.text = (document.text as NSString).replacingCharacters(in: range, with: text)
        document.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
    }
    func selectedRange() -> NSRange { document.selection }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard range.location != NSNotFound, NSMaxRange(range) <= (document.text as NSString).length else { return nil }
        return NSAttributedString(string: (document.text as NSString).substring(with: range))
    }
    func uniqueClientIdentifierString() -> String! { generatesIdentifier ? UUID().uuidString : identity }
    func bundleIdentifier() -> String! { application }
    func setMarkedText(_ value: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func length() -> Int { (document.text as NSString).length }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name: String!) {}
    func selectMode(_ identifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}


private final class Service: NSObject, VoiceServiceProtocol, @unchecked Sendable {
    var requests: [VoiceRequest] = []
    var stopped: [String] = []
    func ping(_ reply: @escaping () -> Void) { reply() }
    func warmUp(_ reply: @escaping (Bool) -> Void) { reply(false) }
    func start(_ data: Data, reply: @escaping (Bool, String) -> Void) {
        requests.append(try! JSONDecoder().decode(VoiceRequest.self, from: data)); reply(true, "")
    }
    func stop(_ id: String) { stopped.append(id) }
    func cancel(_ id: String) {}
}
private final class Connection: NSXPCConnection, @unchecked Sendable {
    let service = Service()
    override func resume() {}
    override func invalidate() {}
    override var remoteObjectProxy: Any { service }
    override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (any Error) -> Void) -> Any { service }
    func send(_ event: VoiceEvent) { (exportedObject as? any VoiceObserverProtocol)?.receive(try! JSONEncoder().encode(event)) }
}
@MainActor private final class Host: VoiceHost {
    let owner = InputOwner()
    let client = Client(Document())
    var snapshotReads = 0
    var canCommit = true
    var canStart = true
    var messages: [String] = []
    var effects: [String] = []
    func snapshot(for owner: InputOwner) -> InputSnapshot? {
        snapshotReads += 1
        guard owner == self.owner else { return nil }
        return InputSnapshot(client: client, canStart: canStart, canCommit: canCommit)
    }
    func present(_ effect: HostPresentation, for owner: InputOwner) {
        switch effect {
        case .status(let message): messages.append(message); effects.append("status:" + message)
        case .hideCandidates: effects.append("hideCandidates")
        case .restorePanel: effects.append("restorePanel")
        }
    }
}
@main struct VoiceFeatureCheck {
    @MainActor static func settle() async throws { for _ in 0..<100 { try await Task.sleep(for: .milliseconds(2)) } }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = VoiceSettings(); settings.enabled = true; settings.mode = "polish"
        let processing = try JSONDecoder().decode(VoicePolishObservation.Processing.self,
            from: Data(#"{"source":1,"milliseconds":500,"finalCorrections":0}"#.utf8))
        let url = root.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: url)
        let host = Host()
        let connection = Connection(machServiceName: "test.voice.feature")
        let feature = VoiceFeature(host: host, settingsURL: url, makeConnection: { connection }, feedback: { _ in }, captureAnchor: { _ in nil })
        feature.activate(host.owner)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        guard feature.handle(key, owner: host.owner) == .consumed else { fatalError("voice shortcut passed through") }
        try await settle()
        guard let request = connection.service.requests.first else { fatalError("shortcut did not start recognition") }
        connection.send(VoiceEvent(sessionID: request.sessionID, kind: "recording"))
        connection.send(VoiceEvent(sessionID: request.sessionID, kind: "completed", text: "你好GitHub", transcript: "你好github", processing: processing))
        try await settle()
        guard host.client.document.text == "前文你好GitHub" else { fatalError("final text was not committed to the current input") }
        // Releasing a handled shortcut never leaks into the editor.
        let release = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        precondition(feature.handle(release, owner: host.owner) == .consumed)
        precondition(feature.handle(release, owner: host.owner) == .passThrough)

        // A preparation-stop must wait for actual readiness, then stop exactly once.
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let second = connection.service.requests.last!
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        precondition(connection.service.stopped.isEmpty)
        connection.send(VoiceEvent(sessionID: second.sessionID, kind: "recording"))
        try await settle()
        precondition(connection.service.stopped == [second.sessionID])
        connection.send(VoiceEvent(sessionID: second.sessionID, kind: "recording"))
        try await settle()
        precondition(connection.service.stopped.count == 1)

        // An old result must not commit after deactivation or poison a new session.
        feature.deactivate(host.owner)
        precondition(feature.isIdle)
        feature.activate(host.owner)
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let third = connection.service.requests.last!
        connection.send(VoiceEvent(sessionID: second.sessionID, kind: "completed", text: "旧内容"))
        try await settle()
        precondition(host.client.document.text == "前文你好GitHub")
        host.canCommit = false
        connection.send(VoiceEvent(sessionID: third.sessionID, kind: "completed", text: "焦点外内容"))
        try await settle()
        precondition(host.client.document.text == "前文你好GitHub")
        precondition(feature.isIdle)
        // Cleaning up the session restores the panel, which would hide the message at once: it must come last.
        precondition(host.effects.last == "status:输入位置已变化，语音结果未写入", "rejection message was hidden by the panel restore: \(host.effects)")
        host.canCommit = true

        // Ordinary typing passes through and cancels pending speech.
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let fourth = connection.service.requests.last!
        let ordinary = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        precondition(feature.handle(ordinary, owner: host.owner) == .passThrough)
        precondition(feature.isIdle)
        connection.send(VoiceEvent(sessionID: fourth.sessionID, kind: "completed", text: "取消内容"))
        try await settle()
        precondition(host.client.document.text == "前文你好GitHub")
        precondition(feature.handle(key, owner: host.owner) == .consumed)
        try await settle()
        let readsBeforeActivation = host.snapshotReads
        feature.activate(InputOwner())
        precondition(host.snapshotReads == readsBeforeActivation, "activation must not synchronously inspect IMK client")
        feature.shutdown()

        // A bare-modifier rewrite shortcut arrives as flagsChanged, where reading NSEvent.isARepeat raises
        // an exception that would abort the input method for every application.
        var modifierSettings = settings
        modifierSettings.rewriteShortcut = "Alt_R"
        let modifierURL = root.appendingPathComponent("modifier-settings.json")
        try JSONEncoder().encode(modifierSettings).write(to: modifierURL)
        let modifierHost = Host()
        let modifierFeature = VoiceFeature(host: modifierHost, settingsURL: modifierURL,
            makeConnection: { Connection(machServiceName: "test.voice.modifier") }, feedback: { _ in }, captureAnchor: { _ in nil })
        modifierFeature.activate(modifierHost.owner)
        let optionDown = CGEvent(source: nil)!
        optionDown.type = .flagsChanged
        optionDown.flags = .maskAlternate
        optionDown.setIntegerValueField(.keyboardEventKeycode, value: 61)
        precondition(modifierFeature.handle(NSEvent(cgEvent: optionDown)!, owner: modifierHost.owner) == .consumed)
        try await settle()
        modifierFeature.shutdown()

        // Secondary press during stopping must act as an escape hatch to cancel
        let escapeHost = Host()
        let escapeConn = Connection(machServiceName: "test.voice.escape")
        let escapeFeature = VoiceFeature(host: escapeHost, settingsURL: url,
            makeConnection: { escapeConn }, feedback: { _ in }, captureAnchor: { _ in nil })
        escapeFeature.activate(escapeHost.owner)
        precondition(escapeFeature.handle(key, owner: escapeHost.owner) == .consumed)
        try await settle()
        let escapeReq = escapeConn.service.requests.last!
        escapeConn.send(VoiceEvent(sessionID: escapeReq.sessionID, kind: "recording"))
        try await settle()
        // First press to stop: enters transcribing
        precondition(escapeFeature.handle(key, owner: escapeHost.owner) == .consumed)
        precondition(!escapeFeature.isIdle)
        // Second press while stopping: escape hatch cancels
        precondition(escapeFeature.handle(key, owner: escapeHost.owner) == .consumed)
        precondition(escapeFeature.isIdle)
        precondition(escapeHost.effects.last == "status:语音任务已取消", "secondary press must cancel and show status")
        escapeFeature.shutdown()

        // Early stop race must not play start cue or spawn anchor task
        var cueLog: [String] = []
        let cueHost = Host()
        let cueConn = Connection(machServiceName: "test.voice.cue")
        let cueFeature = VoiceFeature(host: cueHost, settingsURL: url,
            makeConnection: { cueConn }, feedback: { effect in
                switch effect {
                case .cue(let rec): cueLog.append("cue:\(rec)")
                case .state(let st): cueLog.append("state:\(st)")
                default: break
                }
            }, captureAnchor: { _ in fatalError("anchorTask should not spawn on early stop") })
        cueFeature.activate(cueHost.owner)
        precondition(cueFeature.handle(key, owner: cueHost.owner) == .consumed)
        try await settle()
        let cueReq = cueConn.service.requests.last!
        // Stop before recording event arrives
        precondition(cueFeature.handle(key, owner: cueHost.owner) == .consumed)
        // Now recording event arrives late
        cueConn.send(VoiceEvent(sessionID: cueReq.sessionID, kind: "recording"))
        try await settle()
        precondition(!cueLog.contains("cue:true"), "start cue must not play if user already stopped")
        precondition(cueConn.service.stopped.contains(cueReq.sessionID), "stop must be forwarded to bridge")
        cueConn.send(VoiceEvent(sessionID: cueReq.sessionID, kind: "transcribing"))
        try await settle()
        precondition(!cueLog.contains("cue:false"), "stop cue must not play if start cue was never played")
        cueFeature.shutdown()

        // Hold mode with compound shortcut: releasing key then releasing modifier must NOT cancel session
        let holdHost = Host()
        var holdSettings = settings
        holdSettings.recordingGesture = "hold"
        holdSettings.toggleShortcut = "Control+space"
        let holdURL = root.appendingPathComponent("hold-settings.json")
        try JSONEncoder().encode(holdSettings).write(to: holdURL)
        let holdConn = Connection(machServiceName: "test.voice.hold")
        let holdFeature = VoiceFeature(host: holdHost, settingsURL: holdURL,
            makeConnection: { holdConn }, feedback: { _ in }, captureAnchor: { _ in nil })
        holdFeature.activate(holdHost.owner)
        // Press Control+Space down
        let spaceDown = CGEvent(source: nil)!
        spaceDown.type = .keyDown
        spaceDown.flags = .maskControl
        spaceDown.setIntegerValueField(.keyboardEventKeycode, value: 49) // space
        precondition(holdFeature.handle(NSEvent(cgEvent: spaceDown)!, owner: holdHost.owner) == .consumed)
        try await settle()
        let holdReq = holdConn.service.requests.last!
        holdConn.send(VoiceEvent(sessionID: holdReq.sessionID, kind: "recording"))
        try await settle()
        // Release space first (keyUp)
        let spaceUp = CGEvent(source: nil)!
        spaceUp.type = .keyUp
        spaceUp.flags = .maskControl
        spaceUp.setIntegerValueField(.keyboardEventKeycode, value: 49)
        _ = holdFeature.handle(NSEvent(cgEvent: spaceUp)!, owner: holdHost.owner)
        precondition(!holdFeature.isIdle, "session should be stopping/transcribing, not idle")
        precondition(holdHost.effects.last != "status:语音任务已取消", "releasing key must not cancel voice")
        // Now release Control (flagsChanged with missing control modifier)
        let ctrlUp = CGEvent(source: nil)!
        ctrlUp.type = .flagsChanged
        ctrlUp.flags = []
        ctrlUp.setIntegerValueField(.keyboardEventKeycode, value: 59)
        _ = holdFeature.handle(NSEvent(cgEvent: ctrlUp)!, owner: holdHost.owner)
        precondition(!holdFeature.isIdle, "session should still be transcribing, not cancelled on modifier release")
        precondition(holdHost.effects.last != "status:语音任务已取消", "releasing modifier must not cancel voice")
        // Pressing shortcut again while stopping acts as escape hatch to cancel
        precondition(holdFeature.handle(NSEvent(cgEvent: spaceDown)!, owner: holdHost.owner) == .consumed)
        precondition(holdFeature.isIdle, "pressing shortcut again during hold stopping must cancel")
        precondition(holdHost.effects.last == "status:语音任务已取消", "escape hatch must show cancelled status")
        holdFeature.shutdown()

        // Missed modifier key-up must not permanently desynchronize state or swallow subsequent presses
        let resyncHost = Host()
        var ctrlSettings = settings
        ctrlSettings.rewriteShortcut = "Control_R"
        let ctrlURL = root.appendingPathComponent("ctrl-settings.json")
        try JSONEncoder().encode(ctrlSettings).write(to: ctrlURL)
        let resyncFeature = VoiceFeature(host: resyncHost, settingsURL: ctrlURL,
            makeConnection: { Connection(machServiceName: "test.voice.ctrl") }, feedback: { _ in }, captureAnchor: { _ in nil })
        resyncFeature.activate(resyncHost.owner)
        let ctrlDown = CGEvent(source: nil)!
        ctrlDown.type = .flagsChanged
        ctrlDown.flags = .maskControl
        ctrlDown.setIntegerValueField(.keyboardEventKeycode, value: 62)
        precondition(resyncFeature.handle(NSEvent(cgEvent: ctrlDown)!, owner: resyncHost.owner) == .consumed)
        // Key-up missed! Another event arrives with Control flag cleared
        let otherEvent = CGEvent(source: nil)!
        otherEvent.type = .flagsChanged
        otherEvent.flags = []
        otherEvent.setIntegerValueField(.keyboardEventKeycode, value: 58)
        _ = resyncFeature.handle(NSEvent(cgEvent: otherEvent)!, owner: resyncHost.owner)
        // Now Control_R is pressed down again; it must NOT be swallowed
        precondition(resyncFeature.handle(NSEvent(cgEvent: ctrlDown)!, owner: resyncHost.owner) == .consumed, "subsequent modifier press must not be swallowed after missed key-up")
        resyncFeature.shutdown()

        print("PASS VoiceFeature shortcut, commit, preparation-stop, duplicate readiness, stale event, focus rejection, ordinary-key cancellation, bare-modifier rewrite key, escape hatch, early stop cue, modifier resync")
    }
}
